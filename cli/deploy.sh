# nixhold deploy [<name>…|--all] [--mode {switch|boot|test}] [--dry-run]
#                                [--target <addr>]
#
# Daily verb. Builds + activates each host's current config.
#   - No name: this machine (nh_deploy_self); a usage error when it
#     is not a fleet host. --all: every host this machine can
#     activate (every NixOS host, every Android host; a darwin host
#     only when this Mac is it). Naming is the confirmation: no
#     picker, no prompt.
#   - Local mode iff <name> is this machine: nixos-rebuild / darwin-rebuild.
#   - Remote NixOS: nixos-rebuild --target-host <addr> --build-host <addr>
#     (the target builds itself; we orchestrate).
#   - Remote darwin: refused (deploy Macs locally).
#   - Android: the plan is built here and the device converged onto
#     it over adb (deploy-android.sh); --mode does not apply.
# Several hosts deploy in order; a failure on one does not abandon
# the rest, and the verb reports the failed set at the end.
#
# Before the build: required secrets with no ciphertext are
# provisioned, then the host is made to hold the fleet key. That check
# is a `cat /etc/nixhold/fleet.pub` compared with keys/fleet.pub — free
# when they agree, and only when they do not does the verb open
# keys/fleet.key.age (a passphrase prompt, or a touch of the operator's
# FIDO2 token) and install it. No rekey: every host reads every secret
# with that one key, so a host joining the fleet changes no ciphertext.

# The required-secret walk lives in the sibling verb.
# shellcheck source=secret-edit.sh
. "$NIXHOLD_LIB_ROOT/secret-edit.sh"
# shellcheck source=deploy-android.sh
. "$NIXHOLD_LIB_ROOT/deploy-android.sh"

cmd_deploy() {
  local names=() mode="switch" mode_given=0 dry_run=0 target="" all=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --mode) mode="$2"; mode_given=1; shift 2 ;;
      --dry-run) dry_run=1; shift ;;
      --target) target="$2"; shift 2 ;;
      --all) all=1; shift ;;
      -h | --help)
        cat <<'EOF'
Usage: nixhold deploy [<name>…|--all] [--mode {switch|boot|test}] [--dry-run]
                                      [--target <addr>]

  No name deploys this machine; --all every host it can activate.
EOF
        return 0
        ;;
      -*) nh_err "unknown flag: $1"; return 1 ;;
      *) names+=("$1"); shift ;;
    esac
  done
  case "$mode" in switch | boot | test) ;; *) nh_err "unknown mode: $mode"; return 1 ;; esac
  nh_require_cmd nix
  nh_fleet_root >/dev/null || return 1

  if [ "$all" -eq 1 ]; then
    if [ "${#names[@]}" -gt 0 ]; then
      nh_err "--all takes no host names"
      return 1
    fi
    local line
    while IFS= read -r line; do
      [ -n "$line" ] && names+=("$line")
    done < <(nh_deploy_eligible)
    if [ "${#names[@]}" -eq 0 ]; then
      nh_err "no host in the fleet can be deployed from this machine"
      return 1
    fi
  elif [ "${#names[@]}" -eq 0 ]; then
    local self
    self="$(nh_deploy_self)" || {
      nh_err "this machine ($(nh_hostname)) is not a fleet host — nixhold deploy <name>, or --all for every host it can activate"
      return 1
    }
    names=("$self")
  fi
  if [ -n "$target" ] && [ "${#names[@]}" -ne 1 ]; then
    nh_err "--target applies to exactly one host"
    return 1
  fi
  if [ "$mode_given" -eq 1 ]; then
    local n
    for n in "${names[@]}"; do
      if [ "$(nh_host_platform "$n" 2>/dev/null || true)" = "android" ]; then
        nh_err "--mode does not apply to $n: an Android host is converged, not switched"
        return 1
      fi
    done
  fi

  nh_info "deploy: ${names[*]} — mode=$mode$([ "$dry_run" -eq 1 ] && printf ' dry-run')"

  local name failed=()
  for name in "${names[@]}"; do
    [ "${#names[@]}" -eq 1 ] || nh_info "── deploy $name"
    nh_deploy_host "$name" "$mode" "$dry_run" "$target" || failed+=("$name")
  done
  if [ "${#failed[@]}" -gt 0 ]; then
    nh_err "deploy failed: ${failed[*]}"
    return 1
  fi
  [ "${#names[@]}" -eq 1 ] || nh_ok "deployed: ${names[*]}"
}

# nh_deploy_self — the fleet host this machine is; non-zero when it is
# none of them. Match by hostname, and on a Mac fall back to the
# fleet's only darwin host — the fleet name and the macOS/MDM hostname
# routinely differ (especially before the first switch).
nh_deploy_self() {
  local here macs
  here="$(nh_hostname)"
  if nh_all_hosts | grep -qx -- "$here"; then
    printf '%s' "$here"
    return 0
  fi
  [ "$(uname -s)" = "Darwin" ] || return 1
  macs="$(nh_hosts darwin | cut -d' ' -f1)"
  case "$macs" in
    "" | *$'\n'*) return 1 ;;
  esac
  printf '%s' "$macs"
}

# nh_deploy_eligible — the hosts this machine can activate, one per
# line: every NixOS host (the target builds its own closure), every
# Android host (this machine builds the plan and drives adb), plus a
# darwin host only when this Mac is it.
nh_deploy_eligible() {
  local self line name platform
  self="$(nh_deploy_self)" || self=""
  while IFS= read -r line; do
    name="${line%% *}"
    platform="${line##* }"
    if [ "$platform" = "nixos" ] || [ "$platform" = "android" ] || [ "$name" = "$self" ]; then
      printf '%s\n' "$name"
    fi
  done < <(nh_hosts)
}

# nh_deploy_host <name> <mode> <dry-run> <target> — one host.
nh_deploy_host() {
  local name="$1" mode="$2" dry_run="$3" target="$4" root platform arch
  root="$(nh_fleet_root)" || return 1
  platform="$(nh_host_platform "$name")" || {
    nh_err "host '$name' is not in this fleet — 'nixhold status --fleet' lists the roster"
    return 1
  }
  arch="$(nh_host_arch "$name")"

  local local_host=0
  if [ "$(nh_deploy_self 2>/dev/null || true)" = "$name" ]; then
    local_host=1
  fi

  # Required secrets with no ciphertext are provisioned first: it can
  # open editors/run generators, and a failure aborts — activation
  # would only fail later with a much worse error.
  nh_provision_required_secrets "$name" "$platform" || {
    nh_err "secret provisioning failed — fix the secrets above, then re-run deploy"
    return 1
  }

  # An Android host holds no fleet key and takes no ssh: nothing
  # below applies. Its plan is built here and applied over adb.
  if [ "$platform" = "android" ]; then
    nh_android_deploy "$name" "$dry_run" "$target"
    return $?
  fi

  # The address is resolved here rather than in the nixos branch below:
  # the fleet-key check travels over the same connection, and a host
  # nothing can reach must fail before the build rather than after it.
  local user addr
  if [ "$platform" = "nixos" ] && [ "$local_host" -ne 1 ]; then
    user="$(nh_host_eval "$name" "$platform" "nixhold.identity.username" | jq -r '.')"
    if [ -z "$target" ]; then
      addr="$(nh_deploy_addr "$name")"
      [ -z "$addr" ] && {
        nh_err "could not resolve deploy address for $name (on the tailnet yet? pass --target <addr>)"
        return 1
      }
      target="${user}@${addr}"
    else
      case "$target" in
        *@*) ;;
        *) target="${user}@${target}" ;;
      esac
    fi
  fi

  # Then the other half of "this host must be able to read what it
  # declares": every secret is encrypted to the ONE fleet key, so the
  # only thing a host needs is that key at /etc/nixhold/fleet.key. The
  # machine's own /etc/nixhold/fleet.pub says which one it holds, so
  # this is a comparison first and an install only on a mismatch —
  # which is what makes a routine deploy prompt for nothing.
  local sync=()
  if [ "$platform" = "nixos" ] && [ "$local_host" -ne 1 ] && [ -n "$target" ]; then
    sync=(--remote "$target" --host "$name")
  fi
  nh_fleet_key_sync "${sync[@]}" || {
    nh_err "$name does not hold the fleet key — it would activate unable to decrypt any secret"
    return 1
  }

  local args=("$mode")
  case "$platform" in
    nixos)
      nh_require_cmd nixos-rebuild
      [ "$dry_run" -eq 1 ] && args=(dry-build)
      if [ "$local_host" -eq 1 ]; then
        (cd "$root" && sudo nixos-rebuild "${args[@]}" --flake ".#$name")
      else
        # Connect as the operator user (+ --elevate=sudo), not root:
        # the hardened openssh preset is prohibit-password and no root
        # authorized key is planted, so the operator user is the only
        # way in. Its sudo asks for a password, and the remote session
        # has no terminal to type one into — hence
        # --ask-elevate-password, which prompts HERE (getpass on the
        # local tty) once per host and feeds the answer to the
        # target's `sudo --stdin`. Same mechanism as lib/ssh.sh's
        # nh_ssh_sudo, implemented by nixos-rebuild itself.
        #
        # nixos-rebuild spawns its own ssh; $NIX_SSHOPTS is the only way
        # in. Pin it to $name's committed host key exactly as nh_ssh
        # does, so a deploy cannot activate a closure on whatever
        # answered at that address. Nothing to pin (no keys/hosts/<n>.pub
        # yet, or a scratch path ssh's word-split env var cannot carry)
        # leaves ssh on its own known_hosts, which asks rather than
        # assumes.
        local pin="" pinrc=0
        pin="$(nh_ssh_pin_opts "$name" "${target##*@}")" || pinrc=$?
        case "$pinrc" in
          0) ;;
          1) nh_info "no committed host key for $name yet — ssh verifies $target against your own known_hosts" ;;
          *)
            pin=""
            nh_warn "could not pin $target to $name's committed host key — ssh falls back to your own known_hosts"
            ;;
        esac
        NIX_SSHOPTS="${NIX_SSHOPTS:-}${pin:+ $pin}" \
          nixos-rebuild "${args[@]}" \
          --flake "$root#$name" \
          --target-host "$target" \
          --build-host "$target" \
          --elevate=sudo \
          --ask-elevate-password
      fi
      ;;
    darwin)
      # darwin deploys are always local — so gate on the OS, not on
      # nh_deploy_self, which a fleet of several Macs with a hostname
      # that matches none of them cannot resolve.
      if [ "$(uname -s)" != "Darwin" ]; then
        nh_err "darwin hosts deploy locally only — run this on $name itself"
        return 1
      fi
      if [ "$local_host" -ne 1 ]; then
        nh_warn "local hostname is '$(nh_hostname)', not '$name' — assuming this machine IS $name (darwin deploys are local-only)"
      fi
      if ! command -v darwin-rebuild >/dev/null 2>&1; then
        nh_err "darwin-rebuild not on PATH — the first activation goes through 'nixhold host install $name'"
        return 1
      fi
      [ "$dry_run" -eq 1 ] && args=(check)
      # nix-darwin requires root for switch (since the 25.05-era
      # activation refactor), same as the NixOS path.
      (cd "$root" && sudo darwin-rebuild "${args[@]}" --flake ".#$name")
      ;;
    *)
      nh_err "unsupported arch for $name: $arch"
      return 1
      ;;
  esac
}
