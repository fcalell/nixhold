# nixhold deploy <name> [--mode {switch|boot|test}] [--dry-run]
#                       [--target <addr>] [--yes]
#
# Daily verb. Builds + activates a host's current config.
#   - Local mode iff `hostname` == <name>: nixos-rebuild / darwin-rebuild.
#   - Remote NixOS: nixos-rebuild --target-host <addr> --build-host <addr>
#     (the target builds itself; we orchestrate).
#   - Remote darwin: refused in v1.

cmd_deploy() {
  local name="" mode="switch" dry_run=0 target="" yes=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --mode) mode="$2"; shift 2 ;;
      --dry-run) dry_run=1; shift ;;
      --target) target="$2"; shift 2 ;;
      --yes) yes=1; shift ;;
      -h | --help)
        cat <<'EOF'
Usage: nixhold deploy <name> [--mode {switch|boot|test}] [--dry-run]
                              [--target <addr>] [--yes]
EOF
        return 0
        ;;
      -*) nh_err "unknown flag: $1"; return 1 ;;
      *) if [ -z "$name" ]; then name="$1"; shift; else nh_err "extra arg: $1"; return 1; fi ;;
    esac
  done
  if [ -z "$name" ]; then
    nh_err "expected: nixhold deploy <name>"
    return 1
  fi

  nh_require_cmd nix
  local root
  root="$(nh_fleet_root)" || return 1

  local arch platform
  if arch="$(nh_host_eval "$name" nixos "nixhold.fleet.derived.self.arch" 2>/dev/null)"; then
    platform="nixos"
  elif arch="$(nh_host_eval "$name" darwin "nixhold.fleet.derived.self.arch" 2>/dev/null)"; then
    platform="darwin"
  else
    nh_err "host '$name' not found in fleet"
    return 1
  fi
  arch="$(printf '%s' "$arch" | jq -r '.')"

  local local_host=0
  if [ "$(hostname -s 2>/dev/null || hostname)" = "$name" ]; then
    local_host=1
  fi

  if [ "$yes" -ne 1 ]; then
    nh_info "deploy $name ($platform, $arch) — mode=$mode dry_run=$dry_run"
    nh_prompt_confirm "Proceed?" || { nh_info "aborted"; return 0; }
  fi

  # Auto-walk secret bootstrap if a required secret has no ciphertext
  # yet (the former standalone `secret bootstrap` verb, folded into the
  # normal deploy flow per the lifecycle design). After the confirm —
  # it can open editors/run generators. A failure aborts: activation
  # would only fail later with a much worse error.
  . "$NIXHOLD_LIB_ROOT/secret-bootstrap.sh"
  nh_bootstrap_if_missing "$name" "$platform" || {
    nh_err "secret bootstrap failed — fix the secrets above, then re-run deploy"
    return 1
  }

  case "$platform" in
    nixos)
      if [ "$local_host" -eq 1 ]; then
        nh_require_cmd nixos-rebuild
        local args=(switch)
        [ "$mode" != "switch" ] && args=("$mode")
        [ "$dry_run" -eq 1 ] && args=(dry-build)
        ( cd "$root" && sudo nixos-rebuild "${args[@]}" --flake ".#$name" )
      else
        nh_require_cmd nixos-rebuild
        # Connect as the operator user (+ --use-remote-sudo), not root:
        # the hardened openssh preset is prohibit-password and no root
        # authorized key is planted; the operator user is authorized.
        local user addr
        user="$(nh_host_eval "$name" "$platform" "nixhold.identity.username" | jq -r '.')"
        if [ -z "$target" ]; then
          addr="$(nh_deploy_addr "$name" "$platform")"
          [ -z "$addr" ] && { nh_err "could not resolve deploy address for $name (on the tailnet yet? pass --target <addr>)"; return 1; }
          target="${user}@${addr}"
        else
          case "$target" in *@*) ;; *) target="${user}@${target}" ;; esac
        fi
        local args=(switch)
        [ "$mode" != "switch" ] && args=("$mode")
        [ "$dry_run" -eq 1 ] && args=(dry-build)
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
      # v1: darwin deploys are always local — so gate on the OS, not
      # the hostname. The fleet name and the macOS/MDM hostname
      # routinely differ (especially before the first switch).
      if [ "$(uname -s)" != "Darwin" ]; then
        nh_err "darwin hosts deploy locally only (v1) — run this on $name itself"
        return 1
      fi
      if [ "$local_host" -ne 1 ]; then
        nh_warn "local hostname is '$(hostname -s 2>/dev/null || hostname)', not '$name' — assuming this machine IS $name (darwin deploys are local-only)"
      fi
      if ! command -v darwin-rebuild >/dev/null 2>&1; then
        nh_err "darwin-rebuild not on PATH — the first activation goes through 'nixhold host install $name'"
        return 1
      fi
      local args=(switch)
      [ "$mode" != "switch" ] && args=("$mode")
      [ "$dry_run" -eq 1 ] && args=(check)
      # nix-darwin requires root for switch (since the 25.05-era
      # activation refactor), same as the NixOS path.
      ( cd "$root" && sudo darwin-rebuild "${args[@]}" --flake ".#$name" )
      ;;
  esac
}
