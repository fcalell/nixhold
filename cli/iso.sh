# nixhold iso [--flash <device>]
#
# Builds this fleet's installer image — `packages.<arch>.installerIso`
# — and optionally writes it to a USB stick. The image is the
# no-other-machine install path: it carries the CLI, the operator's
# login keys, the wrapped operator identity and the repo deploy key,
# so a bare target reaches the fleet with nothing but the passphrase.
#
# The deploy key is this verb's other job: it is generated + escrowed
# here (`nh_ensure_repo_deploy_key`) because the ISO is the only
# artifact that needs it.

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
  # that doesn't know its repo can't clone anything — refuse before
  # generating a deploy key for a repo we can't name.
  local repo
  repo="$(nh_layout repoUrl 2>/dev/null | jq -r '. // empty')" || repo=""
  if [ -z "$repo" ]; then
    nh_err "layout.repoUrl is unset — set it to \"owner/repo\" in your mkFleet call; the installer image has to know which fleet repo to clone"
    return 1
  fi

  # ISOs are Linux images built with Linux builders; a mac has neither.
  # No cross-build fallback: the operator has a Linux fleet machine (the
  # ISO only exists for fleets with Linux hosts). Checked before the
  # deploy key: a refusal that first generates a key and asks the
  # operator to register it on GitHub wastes the one irreversible step
  # in this verb.
  if [ "$(uname -s)" = "Darwin" ]; then
    nh_err "installer ISOs build on Linux only — run 'nixhold iso' from a Linux fleet machine"
    return 1
  fi

  # Fresh-key detection: nh_ensure_repo_deploy_key is idempotent and
  # silent on the already-escrowed path, so ask the filesystem which
  # path it took. A brand-new key is useless until it is registered on
  # the git host, so stop and say so rather than burning a build.
  local keys_dir had_key=0
  keys_dir="$(nh_worktree_keys_dir)" || return 1
  [ -f "$keys_dir/repo.key.age" ] && had_key=1
  nh_ensure_repo_deploy_key || return 1
  if [ "$had_key" -eq 0 ]; then
    nh_commit_paths "$root" "keys: repo deploy key" "$keys_dir/repo.key.age"
    nh_warn "the image is inert until that pubkey is registered on $repo as a deploy key WITH WRITE ACCESS"
    if ! nh_prompt_confirm "Deploy key registered — build the image now?"; then
      nh_info "aborted — re-run 'nixhold iso' once the key is registered"
      return 0
    fi
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
    nh_err "ISO build failed — a missing keys/operator.age or keys/repo.key.age is the usual cause"
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
