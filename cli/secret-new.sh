# nixhold secret new <host> <name>
#
# Creates secrets/hosts/<host>/<name>.age by opening $EDITOR on an
# empty buffer and encrypting to the secret's declared recipients
# (operator + host key, from `nixhold.secrets.<name>.recipients`).
# The secret must already be declared on the host.

cmd_secret_new() {
  local host="${1:-}" name="${2:-}"
  if [ -z "$host" ] || [ -z "$name" ]; then
    nh_err "expected: nixhold secret new <host> <name>"
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
  if [ -e "$target" ]; then
    nh_err "$target already exists — use 'secret edit'"
    return 1
  fi
  json="$(nh_host_eval "$host" "$platform" nixhold.secrets)" || return 2

  (
    set -euo pipefail
    rfile="$(mktemp -t nixhold-rcpt.XXXXXX)"
    tmp="$(mktemp -t nixhold-secret.XXXXXX)"
    chmod 600 "$tmp"
    trap 'rm -f "$rfile" "$tmp"' EXIT

    nh_recipients_file "$json" "$name" "$rfile"
    "${EDITOR:-vi}" "$tmp"
    if [ ! -s "$tmp" ]; then
      nh_warn "empty content — not writing $name"
      exit 1
    fi
    mkdir -p "$(dirname "$target")"
    age -R "$rfile" -o "$target" "$tmp"
    nh_ok "wrote $target"
  )
}
