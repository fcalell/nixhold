# nixhold host key <name> [--remote <user>@<ip>] [--yes]
#
# Make the machine and the repo agree about <name>'s host key. The
# decision procedure is nh_reconcile_host_key (lib/escrow.sh) — the
# same one `host install` runs on darwin — and the repo wins: the
# fleet's key goes back on a machine that drifted whenever the fleet
# can produce it, the machine's key is adopted only when the fleet
# has nothing, and adoption is refused when it would strand
# ciphertexts (that is a `host rotate-key`). An adoption rekeys the
# host's secrets to the new recipient in the same run.
#
# It exists because the machine can end up holding a key the fleet
# never escrowed — a host installed before the escrow existed, a key
# minted in place on a fresh macOS, a rotation the machine never
# received — and until they agree the recovery contract (repo +
# passphrase re-images any host) is quietly broken.

cmd_host_key() {
  local name="" remote="" yes=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --remote) remote="${2:-}"; shift 2 ;;
      --yes) yes=1; shift ;;
      -h | --help)
        cat <<'EOF'
Usage: nixhold host key <name> [--remote <user>@<ip>] [--yes]

  Reads the key <name>'s machine is running and makes machine and
  repo agree: same key, the escrow is refreshed; the fleet holds
  the committed key, it goes back on the machine; the fleet holds
  none, the machine's key is adopted and the secrets rekeyed.

  --remote      act over SSH (connect as root, or as a
                passwordless-sudo user). Without it the machine is
                THIS one, which must be <name>.
EOF
        return 0
        ;;
      -*) nh_err "unknown flag: $1"; return 1 ;;
      *) if [ -z "$name" ]; then name="$1"; shift; else nh_err "extra arg: $1"; return 1; fi ;;
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
    nh_err "this machine is '$(hostname -s 2>/dev/null || hostname)', not '$name' — run this on $name, or pass --remote <user>@<ip>"
    return 1
  }

  nh_reconcile_host_key "$name" "$target" "$yes" || return 1

  if [ "$_NH_KEY_ADOPTED" -eq 1 ]; then
    nh_info "re-encrypting secrets to include the adopted recipient"
    . "$NIXHOLD_LIB_ROOT/secret-rekey.sh"
    cmd_secret_rekey || {
      nh_err "rekey failed — $name's secrets are NOT decryptable by its key yet; fix and re-run 'nixhold host key $name'"
      return 1
    }
  fi
  nh_ok "$name: machine and repo agree"
  nh_info "next: commit keys/hosts/$name (and secrets/ if rekeyed), then 'nixhold deploy $name'"
}
