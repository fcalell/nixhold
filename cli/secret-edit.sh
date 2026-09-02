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
    # One 0700 dir so the buffer can carry an identifying name
    # (<host>.<name>, what the editor shows) without publishing it in a
    # world-readable /tmp listing. Attr names are normally
    # filename-safe; sanitized anyway so a quoted name cannot escape
    # the workdir.
    workdir="$(mktemp -d -t nixhold-secret.XXXXXX)" || exit 2
    chmod 700 "$workdir"
    trap 'rm -rf "$workdir"' EXIT
    rfile="$workdir/recipients"
    idfile="$workdir/identity"
    safe="$host.$name"
    safe="${safe//[^A-Za-z0-9._-]/_}"
    tmp="$workdir/$safe"
    : >"$idfile"
    : >"$tmp"
    chmod 600 "$idfile" "$tmp"

    nh_recipients_file "$json" "$host" "$name" "$rfile" || exit 1
    nh_unwrap_identity "$idfile" || exit 1
    age -d -i "$idfile" -o "$tmp" "$target" || {
      nh_err "could not decrypt $target with the operator identity"
      exit 1
    }
    # The plaintext is encrypted back byte-for-byte, so nothing is ever
    # prefilled into the buffer: identity lives in its filename.
    nh_info "opening $(nh_editor_cmd) for $host/$name"
    nh_run_editor "$tmp" || exit 1
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
