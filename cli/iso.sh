# nixhold iso [--flash <device>]
#
# Builds this fleet's installer image — `packages.<arch>.installerIso`
# — and optionally writes it to a USB stick. The image is the
# no-other-machine install path; it carries:
#   - the CLI, with the age plugin and libfido2;
#   - keys/login.pub authorized on the ISO's root, so the operator can
#     ssh into a booted target (an empty login.pub is refused: the
#     image would boot unreachable);
#   - secrets/identity.age as the CLONE credential — the fleet's own
#     ssh key is already registered on the forge, so there is no
#     separate repo deploy key any more;
#   - keys/operator.age WHEN THE FLEET HAS ONE — a token-only fleet
#     bakes none, and the operator brings the token instead.
# Either way a bare target reaches the fleet with nothing but the
# operator's seat. This verb generates nothing: everything it bakes is
# already in the repo.

cmd_iso() {
  local device=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --flash)
        device="${2:-}"
        if [ -z "$device" ]; then
          nh_err "--flash expects a device (e.g. /dev/sdb)"
          return 1
        fi
        shift 2
        ;;
      -h | --help)
        cat <<'EOF'
Usage: nixhold iso [--flash <device>]
EOF
        return 0
        ;;
      *)
        nh_err "unknown argument: $1"
        return 1
        ;;
    esac
  done

  nh_require_cmd nix jq || return 1
  local root
  root="$(nh_fleet_root)" || return 1

  # `repoUrl` is the one layout field nothing can derive, and an image
  # that doesn't know its repo can't clone anything.
  local repo
  repo="$(nh_layout repoUrl 2>/dev/null | jq -r '. // empty')" || repo=""
  if [ -z "$repo" ]; then
    nh_err "layout.repoUrl is unset — set it to \"owner/repo\" in your mkFleet call; the installer image has to know which fleet repo to clone"
    return 1
  fi

  # An image nobody can decrypt with is not worth building: the whole
  # point of the ISO is that the target reaches the fleet's ciphertexts
  # (the clone key, the fleet key, every secret) from the operator's
  # seat. A fleet with neither a token recipient nor a wrapped identity
  # has no seat to bake or bring. Checked WITHOUT requiring the token
  # to be plugged in right now — the operator builds the image today
  # and carries the token to the target tomorrow — so this reads the
  # committed recipients, not the USB bus.
  nh_probe_recipient_inputs
  if ! nh_age_has_token_recipient && ! nh_age_wrapped_identity >/dev/null; then
    nh_err "this fleet has no operator seat to install with: nixhold.layout.ageRecipient names no FIDO2 token recipient (age1fido2-hmac1…) and there is no wrapped identity at nixhold.layout.ageIdentityWrapped — commit one of the two before building an installer"
    return 1
  fi
  if nh_age_wrapped_identity >/dev/null; then
    nh_info "the image will bake the wrapped operator identity (the passphrase unlocks the target)"
  else
    nh_info "no wrapped identity in this fleet — the image bakes none; bring the FIDO2 token to the target"
  fi

  # The clone credential. `identity` is fleet-scoped, so this is one
  # file for the whole fleet; a fleet that has never provisioned it has
  # nothing for the installer to clone with.
  local sdir keys_dir
  sdir="$(nh_worktree_secrets_dir)" || return 1
  keys_dir="$(nh_worktree_keys_dir)" || return 1
  if [ ! -e "$sdir/identity.age" ]; then
    nh_err "$sdir/identity.age does not exist — the image would have no way to clone $repo; provision it with 'nixhold secret edit <host> identity' and register its pubkey on the forge"
    return 1
  fi

  # Login keys. The ISO authorizes exactly keys/login.pub on root, so
  # an empty one boots a target nobody can ssh into.
  if ! nh_pubkey_lines "$keys_dir/login.pub" >/dev/null 2>&1; then
    nh_err "$keys_dir/login.pub is missing or holds no key — the image would boot unreachable; 'nixhold secret edit <host> identity' writes it on a fleet that has none, or add your own ssh pubkey line"
    return 1
  fi

  # ISOs are Linux images built with Linux builders; a mac has neither.
  # No cross-build fallback: the operator has a Linux fleet machine (the
  # ISO only exists for fleets with Linux hosts).
  if [ "$(uname -s)" = "Darwin" ]; then
    nh_err "installer ISOs build on Linux only — run 'nixhold iso' from a Linux fleet machine"
    return 1
  fi

  local arch
  case "$(uname -m)" in
    x86_64 | amd64) arch="x86_64-linux" ;;
    aarch64 | arm64) arch="aarch64-linux" ;;
    *)
      nh_err "unsupported build arch: $(uname -m)"
      return 1
      ;;
  esac

  nh_info "building $root#packages.$arch.installerIso (fleet $repo)"
  local out
  if ! out="$(nix build --no-link --print-out-paths --no-warn-dirty \
    "$root#packages.$arch.installerIso")"; then
    nh_err "ISO build failed — a missing secrets/identity.age (or a keys/operator.age the fleet still points at) is the usual cause"
    return 1
  fi

  # The image derivation publishes `$out/iso/<name>.iso`; the name
  # carries the nixpkgs release, so glob rather than reconstruct it.
  local iso="" candidate
  for candidate in "$out"/iso/*.iso; do
    if [ -f "$candidate" ]; then
      iso="$candidate"
      break
    fi
  done
  if [ -z "$iso" ]; then
    nh_err "no .iso under $out/iso — the image derivation changed shape"
    return 1
  fi
  nh_ok "built $iso"

  if [ -z "$device" ]; then
    nh_info "flash it with: nixhold iso --flash /dev/<device>"
    return 0
  fi
  nh_flash_iso "$iso" "$device"
}

# nh_flash_iso <iso> <device> — dd the image onto a whole disk. The
# one destructive thing this CLI does to a device it was never told
# about in Nix, so the confirmation defaults to *no* and a mounted
# device is refused outright.
nh_flash_iso() {
  local iso="$1" device="$2"
  nh_require_cmd dd lsblk || return 1

  if [ ! -b "$device" ]; then
    nh_err "$device is not a block device"
    return 1
  fi

  # Any mountpoint on the device or its partitions means it is in use —
  # very often the operator's own root disk.
  if [ -n "$(lsblk -nro MOUNTPOINTS "$device" 2>/dev/null | grep -v '^$' || true)" ]; then
    nh_err "$device (or a partition of it) is mounted — unmount it first, or you picked the wrong disk"
    return 1
  fi

  nh_info "target device:"
  lsblk -o NAME,SIZE,TYPE,TRAN,MODEL,MOUNTPOINTS "$device" >&2 || true

  # gum directly rather than nh_prompt_confirm: this is the one prompt
  # in the CLI that must default to the non-destructive answer.
  if ! gum confirm --default=false \
    "ERASE $device completely and write $(basename "$iso")?"; then
    nh_info "aborted — nothing written"
    return 0
  fi

  local cmd=(dd "if=$iso" "of=$device" bs=4M "oflag=direct,sync" status=progress)
  if [ "$(id -u)" -ne 0 ]; then
    nh_info "writing to $device needs root — sudo will prompt"
    sudo "${cmd[@]}" || {
      nh_err "flash failed"
      return 1
    }
  else
    "${cmd[@]}" || {
      nh_err "flash failed"
      return 1
    }
  fi
  sync
  nh_ok "flashed $device — boot the target from it and run 'nixhold host install'"
}
