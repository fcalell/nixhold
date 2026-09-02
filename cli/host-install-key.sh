# nixhold host install-key <name> [--remote <user>@<ip>] [--yes]
#
# The mirror of `host escrow`: that verb copies the machine's key INTO
# the repo, this one copies the repo's key ONTO the machine. Resolves
# the committed key (cache when it still derives host.pub, else the
# escrow) and installs it as /etc/ssh/ssh_host_ed25519_key.
#
# Writes nothing into the fleet — it is the "finish what rotate-key
# started" step, and the repo side is already done by then. Also the
# way to correct a machine whose key drifted from the committed
# recipient without reformatting it.

# nh_install_committed_key <name> [target] — resolve + install, the
# single implementation `host rotate-key` also calls.
nh_install_committed_key() {
  local name="$1" target="${2:-}" keydir
  keydir="$(nh_tmpdir hostkey)" || return 1
  nh_resolve_host_key "$name" "$keydir" || return 1
  # <name> travels with the target so the connection carrying the
  # private key is pinned to the key the machine is running: the
  # committed one, or — while a rotation is pending — the superseded
  # one `host rotate-key` recorded (see lib/ssh.sh).
  nh_install_host_key "$keydir/ssh_host_ed25519_key" "$target" "$name"
}

cmd_host_install_key() {
  local name="" remote="" yes=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --remote | --target) remote="${2:-}"; shift 2 ;;
      --yes) yes=1; shift ;;
      -h | --help)
        cat <<'EOF'
Usage: nixhold host install-key <name> [--remote <user>@<ip>] [--yes]

  Installs the fleet's committed key for <name> (cache, else the
  escrow) as /etc/ssh/ssh_host_ed25519_key on the machine. Nothing in
  the repo is written.

  --remote      install over SSH (connect as root, or as a
                passwordless-sudo user). Without it the key is
                installed on THIS machine, which must be <name>.
  --target      alias for --remote.
EOF
        return 0
        ;;
      -*) nh_err "unknown flag: $1"; return 1 ;;
      *) if [ -z "$name" ]; then name="$1"; shift; else nh_err "extra arg: $1"; return 1; fi ;;
    esac
  done
  if [ -z "$name" ]; then
    nh_err "expected: nixhold host install-key <name>"
    return 1
  fi
  nh_require_cmd ssh-keygen age jq nix || return 1

  nh_host_platform "$name" >/dev/null || {
    nh_err "host '$name' not found in fleet"
    return 1
  }

  local target
  target="$(nh_key_target "$name" "$remote")" || {
    nh_err "this machine is '$(hostname -s 2>/dev/null || hostname)', not '$name' — run this on $name, or pass --remote <user>@<ip>"
    return 1
  }

  if [ "$yes" -ne 1 ] &&
    ! nh_prompt_confirm "Install $name's committed host key on ${target:-this machine}? (it stops answering with the key it has now)"; then
    nh_info "aborted"
    return 0
  fi

  nh_install_committed_key "$name" "$target" || return 1
  nh_info "if the host's ciphertexts were re-encrypted to this key, follow with 'nixhold deploy $name'"
}
