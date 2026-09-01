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
    nh_err "no such secret: $target (use 'secret bootstrap')"
    return 1
  fi
  json="$(nh_host_eval "$host" "$platform" nixhold.secrets)" || return 2

  # Checked explicitly rather than through errexit: -e is ignored in a
  # subshell whose exit code the caller tests, and this one is a
  # `cmd_secret_edit` away from being called that way.
  (
    set -euo pipefail
    rfile="$(mktemp -t nixhold-rcpt.XXXXXX)" || exit 2
    idfile="$(mktemp -t nixhold-id.XXXXXX)" || exit 2
    tmp="$(mktemp -t nixhold-secret.XXXXXX)" || exit 2
    chmod 600 "$idfile" "$tmp"
    trap 'rm -f "$rfile" "$idfile" "$tmp"' EXIT

    nh_recipients_file "$json" "$name" "$rfile" || exit 1
    nh_unwrap_identity "$idfile" || exit 1
    age -d -i "$idfile" -o "$tmp" "$target" || {
      nh_err "could not decrypt $target with the operator identity"
      exit 1
    }
    "${EDITOR:-vi}" "$tmp"
    # Encrypt to a sibling temp + rename so an age failure can't
    # leave the committed ciphertext truncated.
    age -R "$rfile" -o "$target.tmp" "$tmp" || {
      rm -f "$target.tmp"
      nh_err "re-encryption failed — $target is untouched"
      exit 1
    }
    mv "$target.tmp" "$target" || {
      rm -f "$target.tmp"
      nh_err "could not replace $target — it is untouched"
      exit 1
    }
    nh_ok "updated $target"
  )
}
