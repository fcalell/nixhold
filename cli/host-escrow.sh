# nixhold host escrow <name> [--remote <user>@<ip>]
#
# Re-escrow a host's LIVE key: read /etc/ssh/ssh_host_ed25519_key off
# the machine that is <name> and write keys/hosts/<name>/host.pub +
# host.key.age from it, in one step, from that one private key.
#
# It exists because the machine can end up holding a key the fleet
# never escrowed — a host installed before the escrow existed, a key
# minted in place on a fresh macOS, an escrow left behind by a partial
# rotation. In every such case the repo says host.pub and the machine
# says something else (or the escrow says something else again), and
# the recovery contract — repo + passphrase re-images any host — is
# quietly broken until the live key is captured.
#
# Refuses when the live key is NOT the committed recipient and the host
# already owns ciphertexts: adopting a different key there would leave
# every one of them undecryptable by the host. That case is a rotation
# (`host rotate-key`), not an escrow.

cmd_host_escrow() {
  local name="" remote="" yes=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --remote | --target) remote="${2:-}"; shift 2 ;;
      --yes) yes=1; shift ;;
      -h | --help)
        cat <<'EOF'
Usage: nixhold host escrow <name> [--remote <user>@<ip>] [--yes]

  Re-escrow <name>'s live /etc/ssh/ssh_host_ed25519_key: writes
  keys/hosts/<name>/host.pub and host.key.age from the key the machine
  is actually running, and refreshes the local key cache.

  --remote      read the key over SSH (connect as root, or as a
                passwordless-sudo user). Without it the key is read
                from THIS machine, which must be <name>.
  --target      alias for --remote.
EOF
        return 0
        ;;
      -*) nh_err "unknown flag: $1"; return 1 ;;
      *) if [ -z "$name" ]; then name="$1"; shift; else nh_err "extra arg: $1"; return 1; fi ;;
    esac
  done
  if [ -z "$name" ]; then
    nh_err "expected: nixhold host escrow <name>"
    return 1
  fi
  nh_require_cmd ssh-keygen age jq nix || return 1

  nh_host_platform "$name" >/dev/null || {
    nh_err "host '$name' not found in fleet"
    return 1
  }

  # Where to read the key from (empty = this machine).
  local target
  target="$(nh_key_target "$name" "$remote")" || {
    nh_err "this machine is '$(hostname -s 2>/dev/null || hostname)', not '$name' — run this on $name, or pass --remote <user>@<ip>"
    return 1
  }

  local keys_dir committed sdir live
  keys_dir="$(nh_worktree_keys_dir)" || return 2
  committed="$keys_dir/hosts/$name/host.pub"
  live="$(nh_tmpdir livekey)" || return 1
  nh_read_live_host_key "$live/ssh_host_ed25519_key" "$target" "$name" || return 1

  if nh_key_matches_pub "$live/ssh_host_ed25519_key" "$committed"; then
    nh_info "the live key is the committed recipient — refreshing its escrow"
  elif [ ! -f "$committed" ]; then
    nh_info "no committed recipient for $name yet — adopting the live key"
  else
    # Different key. Adopting it silently would strand every ciphertext
    # the host owns.
    sdir="$(nh_worktree_secrets_dir)" || return 2
    local owned=0 f
    for f in "$sdir/hosts/$name"/*.age; do
      [ -e "$f" ] || continue
      owned=1
      break
    done
    if [ "$owned" -eq 1 ]; then
      nh_err "$name's live key is NOT the key committed as $committed, and $name already owns ciphertexts encrypted to that recipient — escrowing the live key would leave them undecryptable"
      nh_info "either put the committed key back on the machine ('nixhold host install $name'), or rotate: 'nixhold host rotate-key $name' generates a new key, rekeys the secrets and installs it"
      return 1
    fi
    nh_warn "$name's live key differs from $committed, but $name owns no ciphertexts — adopting the live key"
    if [ "$yes" -ne 1 ] && ! nh_prompt_confirm "Replace $committed with the machine's live key?"; then
      nh_info "aborted"
      return 0
    fi
  fi

  nh_escrow_host_key "$name" "$live/ssh_host_ed25519_key" || return 1

  # The cache is now the stale copy: a key that is not the live one is
  # kept aside (it is still the only copy of whatever it was) and the
  # live key takes its place, so the next install/rotate resolves
  # without a passphrase and without reviving a superseded key.
  local cached="$NIXHOLD_CACHE_DIR/host-keys/$name/ssh_host_ed25519_key"
  if [ -f "$cached" ] && ! nh_key_matches_pub "$cached" "$live/ssh_host_ed25519_key.pub"; then
    nh_cache_supersede "$name" || return 1
  fi
  nh_cache_host_key "$name" "$live/ssh_host_ed25519_key" ||
    nh_warn "could not refresh the local key cache for $name"

  nh_ok "escrowed $name's live host key"
  nh_info "commit $keys_dir/hosts/$name/{host.pub,host.key.age}"
}
