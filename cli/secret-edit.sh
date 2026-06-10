# nixhold secret edit <host> <name>
#
# Decrypts an existing secret with the operator identity, opens it in
# $EDITOR, and re-encrypts to the current recipient set.

cmd_secret_edit() {
  local host="${1:-}" name="${2:-}"
  if [ -z "$host" ] || [ -z "$name" ]; then
    nh_err "expected: nixhold secret edit <host> <name>"
    return 1
  fi
  nh_require_cmd age jq nix

  local platform sdir target json
  platform="$(nh_host_platform "$host")" || {
    nh_err "host '$host' not found in fleet"
    return 1
  }
  sdir="$(nh_worktree_secrets_dir)" || return 2
  target="$sdir/hosts/$host/$name.age"
  if [ ! -e "$target" ]; then
    nh_err "no such secret: $target (use 'secret new')"
    return 1
  fi
  json="$(nh_host_eval "$host" "$platform" nixhold.secrets)" || return 2

  (
    set -euo pipefail
    rfile="$(mktemp -t nixhold-rcpt.XXXXXX)"
    idfile="$(mktemp -t nixhold-id.XXXXXX)"
    tmp="$(mktemp -t nixhold-secret.XXXXXX)"
    chmod 600 "$idfile" "$tmp"
    trap 'rm -f "$rfile" "$idfile" "$tmp"' EXIT

    nh_recipients_file "$json" "$name" "$rfile"
    nh_unwrap_identity "$idfile"
    age -d -i "$idfile" -o "$tmp" "$target"
    "${EDITOR:-vi}" "$tmp"
    # Encrypt to a sibling temp + rename so an age failure can't
    # leave the committed ciphertext truncated.
    age -R "$rfile" -o "$target.tmp" "$tmp"
    mv "$target.tmp" "$target"
    nh_ok "updated $target"
  )
}
