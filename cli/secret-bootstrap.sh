# nixhold secret bootstrap <host> [name]
#
# Walks the host's declared secrets (`nixhold.secrets`) — or just
# <name> when given — and provisions any whose ciphertext is missing:
#   - generator set      -> run it, capture stdout, encrypt (non-interactive)
#   - template set        -> prefill $EDITOR with it, encrypt what's saved
#   - neither             -> open an empty $EDITOR, encrypt what's saved
# Idempotent: existing .age files are skipped. Secrets with
# `sshIdentity = true` additionally get their derived pubkey
# committed as keys/hosts/<host>/identity.pub.

cmd_secret_bootstrap() {
  local host="${1:-}" only="${2:-}"
  if [ -z "$host" ]; then
    nh_err "expected: nixhold secret bootstrap <host> [name]"
    return 1
  fi
  nh_require_cmd age jq nix

  local platform sdir json names
  platform="$(nh_host_platform "$host")" || {
    nh_err "host '$host' not found in fleet"
    return 1
  }
  sdir="$(nh_worktree_secrets_dir)" || return 2
  json="$(nh_host_eval "$host" "$platform" nixhold.secrets)" || return 2
  if [ -n "$only" ]; then
    if ! printf '%s' "$json" | jq -e --arg n "$only" 'has($n)' >/dev/null 2>&1; then
      nh_err "secret '$only' is not declared on $host (add nixhold.secrets.$only first)"
      return 1
    fi
    if [ -e "$sdir/hosts/$host/$only.age" ]; then
      nh_err "$sdir/hosts/$host/$only.age already exists — use 'secret edit'"
      return 1
    fi
    names="$only"
  else
    names="$(printf '%s' "$json" | jq -r 'keys[]')"
  fi
  if [ -z "$names" ]; then
    nh_info "no secrets declared on $host"
    return 0
  fi

  local added=0 name target generator template desc
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    target="$sdir/hosts/$host/$name.age"
    if [ -e "$target" ]; then
      nh_info "skip $name (exists)"
      continue
    fi
    generator="$(printf '%s' "$json" | jq -r --arg n "$name" '.[$n].generator // ""')"
    template="$(printf '%s' "$json" | jq -r --arg n "$name" '.[$n].template // ""')"
    desc="$(printf '%s' "$json" | jq -r --arg n "$name" '.[$n].description // ""')"
    nh_info "bootstrap $name${desc:+ — $desc}"

    if (
      set -euo pipefail
      rfile="$(mktemp -t nixhold-rcpt.XXXXXX)"
      tmp="$(mktemp -t nixhold-secret.XXXXXX)"
      chmod 600 "$tmp"
      trap 'rm -f "$rfile" "$tmp"' EXIT

      nh_recipients_file "$json" "$name" "$rfile"
      if [ -n "$generator" ]; then
        nh_info "running generator for $name"
        # The generator is operator-declared config; run it in this
        # already-isolated subshell rather than spawning an external
        # interpreter (bash may not be on the CLI's runtime PATH).
        { eval "$generator"; } >"$tmp"
      elif [ -n "$template" ]; then
        printf '%s' "$template" >"$tmp"
        "${EDITOR:-vi}" "$tmp"
      else
        "${EDITOR:-vi}" "$tmp"
      fi
      if [ ! -s "$tmp" ]; then
        nh_warn "empty content for $name — skipping"
        exit 2
      fi
      mkdir -p "$(dirname "$target")"
      age -R "$rfile" -o "$target" "$tmp"
      nh_ok "encrypted $target"
      if [ "$(printf '%s' "$json" | jq -r --arg n "$name" '.[$n].sshIdentity // false')" = "true" ]; then
        nh_commit_identity_pub "$host" "$tmp" || true
      fi
    ); then
      added=$((added + 1))
    fi
  done <<<"$names"

  if [ "$added" -gt 0 ]; then
    nh_ok "bootstrapped $added secret(s) on $host"
    nh_info "review + commit: git -C \"$(nh_fleet_root)\" add and commit $sdir/hosts/$host"
  else
    nh_info "nothing to bootstrap on $host (all present or skipped)"
  fi
}

# nh_bootstrap_if_missing <host> <platform> — used by `deploy` to
# auto-walk bootstrap when a required secret has no ciphertext yet.
nh_bootstrap_if_missing() {
  local host="$1" platform="$2" sdir json any=0 name
  sdir="$(nh_worktree_secrets_dir)" || return 0
  json="$(nh_host_eval "$host" "$platform" nixhold.secrets 2>/dev/null)" || return 0
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    [ -e "$sdir/hosts/$host/$name.age" ] || any=1
  done < <(printf '%s' "$json" | jq -r 'to_entries[] | select(.value.required) | .key')
  if [ "$any" -eq 1 ]; then
    nh_warn "required secrets missing on $host — running bootstrap first"
    cmd_secret_bootstrap "$host"
  fi
}
