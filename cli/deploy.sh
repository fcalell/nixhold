# nixhold deploy [<name>…] [--mode {switch|boot|test}] [--dry-run]
#                          [--target <addr>] [--yes]
#
# Daily verb. Builds + activates each host's current config.
#   - No name: a multi-select of the hosts this machine can activate
#     (every NixOS host; a darwin host only on that Mac). Picking is
#     the confirmation. --yes with no name = all of them.
#   - Local mode iff `hostname` == <name>: nixos-rebuild / darwin-rebuild.
#   - Remote NixOS: nixos-rebuild --target-host <addr> --build-host <addr>
#     (the target builds itself; we orchestrate).
#   - Remote darwin: refused (deploy Macs locally).
# Several hosts deploy in order; a failure on one does not abandon
# the rest, and the verb reports the failed set at the end.

# The required-secret walk lives in the sibling verb.
# shellcheck source=secret-edit.sh
. "$NIXHOLD_LIB_ROOT/secret-edit.sh"

cmd_deploy() {
  local names=() mode="switch" dry_run=0 target="" yes=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --mode) mode="$2"; shift 2 ;;
      --dry-run) dry_run=1; shift ;;
      --target) target="$2"; shift 2 ;;
      --yes) yes=1; shift ;;
      -h | --help)
        cat <<'EOF'
Usage: nixhold deploy [<name>…] [--mode {switch|boot|test}] [--dry-run]
                                [--target <addr>] [--yes]

  No name picks from the hosts this machine can activate.
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

  if [ "${#names[@]}" -eq 0 ]; then
    local eligible=() line
    while IFS= read -r line; do
      [ -n "$line" ] && eligible+=("$line")
    done < <(nh_deploy_eligible)
    if [ "${#eligible[@]}" -eq 0 ]; then
      nh_err "no host in the fleet can be deployed from this machine"
      return 1
    fi
    if [ "$yes" -eq 1 ]; then
      names=("${eligible[@]}")
    elif nh_tty; then
      local picked
      picked="$(nh_pick_hosts "Deploy which hosts? (mode $mode$([ "$dry_run" -eq 1 ] && printf ', dry-run'))" "${eligible[@]}")" || {
        nh_info "nothing selected"
        return 0
      }
      while IFS= read -r line; do
        [ -n "$line" ] && names+=("$line")
      done <<<"$picked"
      yes=1
    else
      nh_err "expected: nixhold deploy <name> (no terminal for the picker)"
      return 1
    fi
  fi
  if [ -n "$target" ] && [ "${#names[@]}" -ne 1 ]; then
    nh_err "--target applies to exactly one host"
    return 1
  fi

  if [ "$yes" -ne 1 ]; then
    nh_info "deploy: ${names[*]} — mode=$mode$([ "$dry_run" -eq 1 ] && printf ' dry-run')"
    nh_prompt_confirm "Proceed?" || { nh_info "aborted"; return 0; }
  fi

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

# nh_deploy_eligible — the hosts this machine can activate, one per
# line: every NixOS host (the target builds its own closure) plus a
# darwin host only when we ARE that Mac. Match by hostname, falling
# back to "the only mac in the fleet" — the fleet name and the
# macOS/MDM hostname routinely differ.
nh_deploy_eligible() {
  local line name platform macs=0 here
  here="$(hostname -s 2>/dev/null || hostname)"
  macs="$(nh_hosts darwin | wc -l | tr -d ' ')"
  while IFS= read -r line; do
    name="${line%% *}"
    platform="${line##* }"
    case "$platform" in
      nixos) printf '%s\n' "$name" ;;
      darwin)
        [ "$(uname -s)" = "Darwin" ] || continue
        if [ "$here" = "$name" ] || [ "$macs" = 1 ]; then printf '%s\n' "$name"; fi
        ;;
    esac
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
  if [ "$(hostname -s 2>/dev/null || hostname)" = "$name" ]; then
    local_host=1
  fi

  # Required secrets with no ciphertext are provisioned first: it can
  # open editors/run generators, and a failure aborts — activation
  # would only fail later with a much worse error.
  nh_provision_required_secrets "$name" "$platform" || {
    nh_err "secret provisioning failed — fix the secrets above, then re-run deploy"
    return 1
  }

  local args=("$mode")
  case "$platform" in
    nixos)
      nh_require_cmd nixos-rebuild
      [ "$dry_run" -eq 1 ] && args=(dry-build)
      if [ "$local_host" -eq 1 ]; then
        ( cd "$root" && sudo nixos-rebuild "${args[@]}" --flake ".#$name" )
      else
        # Connect as the operator user (+ --use-remote-sudo), not root:
        # the hardened openssh preset is prohibit-password and no root
        # authorized key is planted; the operator user is authorized.
        local user addr
        user="$(nh_host_eval "$name" "$platform" "nixhold.identity.username" | jq -r '.')"
        if [ -z "$target" ]; then
          addr="$(nh_deploy_addr "$name")"
          [ -z "$addr" ] && { nh_err "could not resolve deploy address for $name (on the tailnet yet? pass --target <addr>)"; return 1; }
          target="${user}@${addr}"
        else
          case "$target" in *@*) ;; *) target="${user}@${target}" ;; esac
        fi
        # nixos-rebuild spawns its own ssh; $NIX_SSHOPTS is the only way
        # in. Pin it to $name's committed host key exactly as nh_ssh
        # does, so a deploy cannot activate a closure on whatever
        # answered at that address. Nothing to pin (no host.pub yet, or
        # a scratch path ssh's word-split env var cannot carry) leaves
        # ssh on its own known_hosts, which asks rather than assumes.
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
          --use-remote-sudo
      fi
      ;;
    darwin)
      # darwin deploys are always local — so gate on the OS, not the
      # hostname. The fleet name and the macOS/MDM hostname routinely
      # differ (especially before the first switch).
      if [ "$(uname -s)" != "Darwin" ]; then
        nh_err "darwin hosts deploy locally only — run this on $name itself"
        return 1
      fi
      if [ "$local_host" -ne 1 ]; then
        nh_warn "local hostname is '$(hostname -s 2>/dev/null || hostname)', not '$name' — assuming this machine IS $name (darwin deploys are local-only)"
      fi
      if ! command -v darwin-rebuild >/dev/null 2>&1; then
        nh_err "darwin-rebuild not on PATH — the first activation goes through 'nixhold host install $name'"
        return 1
      fi
      [ "$dry_run" -eq 1 ] && args=(check)
      # nix-darwin requires root for switch (since the 25.05-era
      # activation refactor), same as the NixOS path.
      ( cd "$root" && sudo darwin-rebuild "${args[@]}" --flake ".#$name" )
      ;;
    *)
      nh_err "unsupported arch for $name: $arch"
      return 1
      ;;
  esac
}
