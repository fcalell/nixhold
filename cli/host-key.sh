# nixhold host key <name> [--remote <user>@<ip>]
#
# ADOPTION. Reads the SSH host pubkey the machine is actually running
# and records it as `keys/hosts/<name>.pub` — the file every verb pins
# its connections against, and the only thing the fleet uses a host key
# for. Nothing is escrowed, nothing is rekeyed, no secret changes: a
# host SSH key is a machine identity here, not a recipient.
#
# It exists for the two states that leave the repo's copy stale: a
# machine installed by something other than `nixhold host install`
# (an adopted box, a reinstalled Mac), and a machine whose key was
# regenerated under it — after which every pinned connection fails
# closed, which looks exactly like an attack until the operator has
# checked the fingerprint out of band and run this.
#
# While it is there, it also makes sure the machine holds the fleet
# key: /etc/nixhold/fleet.pub is world-readable, so the comparison is
# free, and a machine that holds the wrong one decrypts nothing at its
# next activation.

cmd_host_key() {
  local name="" remote=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --remote)
        remote="${2:-}"
        shift 2
        ;;
      -h | --help)
        cat <<'EOF'
Usage: nixhold host key <name> [--remote <user>@<ip>]

  Records the SSH host pubkey <name>'s machine is running as
  keys/hosts/<name>.pub — the fleet's known_hosts pin, and the fix
  after a machine's host key was regenerated (check its fingerprint
  out of band first). Re-installs /etc/nixhold/fleet.key when the
  machine holds a different fleet key than the repo names.

  --remote      act over SSH (connect as root, or as the operator —
                its sudo password is prompted for once). Without it
                the machine is THIS one, which must be <name>.
EOF
        return 0
        ;;
      -*)
        nh_err "unknown flag: $1"
        return 1
        ;;
      *)
        if [ -z "$name" ]; then
          name="$1"
          shift
        else
          nh_err "extra arg: $1"
          return 1
        fi
        ;;
    esac
  done
  if [ -z "$name" ]; then
    nh_err "expected: nixhold host key <name>"
    return 1
  fi
  nh_require_cmd ssh-keygen age jq nix || return 1

  nh_host_platform "$name" >/dev/null || {
    nh_err "host '$name' is not in this fleet — 'nixhold status --fleet' lists the roster"
    return 1
  }

  local target
  target="$(nh_key_target "$name" "$remote")" || {
    nh_err "this machine is '$(nh_hostname)', not '$name' — run this on $name, or pass --remote <user>@<ip>"
    return 1
  }

  # A Mac that has never run sshd has no host key to record; mint one
  # in place rather than recording nothing.
  if [ -z "$target" ] && [ "$(uname -s)" = "Darwin" ]; then
    nh_ensure_darwin_host_key || return 1
  fi

  local live
  live="$(nh_read_live_host_pub "$target" "$name")" || return 1

  local out keys_dir root
  keys_dir="$(nh_worktree_keys_dir)" || return 2
  root="$(nh_fleet_root)" || return 1
  out="$(nh_commit_host_pub "$name" "$live")" || return 1
  nh_ok "$name's live host pubkey is recorded at $out"
  nh_commit_paths "$root" "host($name): pubkey" "$keys_dir/hosts/$name.pub"

  # The fleet key, while the connection is open. Reads
  # /etc/nixhold/fleet.pub and installs only on a mismatch, so a
  # machine that already holds the current key costs no unlock.
  local sync=()
  [ -z "$target" ] || sync=(--remote "$target" --host "$name")
  nh_fleet_key_sync "${sync[@]}" || {
    nh_err "$name does not hold the fleet key — it decrypts nothing until it does; fix the operator route and re-run"
    return 1
  }

  nh_info "next: nixhold deploy $name"
}
