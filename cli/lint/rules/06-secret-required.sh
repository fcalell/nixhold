# Rule: every `required = true` secret has ciphertext committed where
# its scope puts it — `secrets/<host>/<name>.age` for a host secret,
# the one `secrets/<name>.age` for a fleet one.
# Replaces the dropped `secret check` verb; the fix is
# `nixhold secret edit <host>`.

sdir="$(nh_worktree_secrets_dir)" || exit 2
worst=0
while IFS= read -r h; do
  [ -n "$h" ] || continue
  platform="$(nh_host_platform "$h")" || {
    echo "ERROR: could not resolve platform for $h — required-secret check skipped"
    [ "$worst" -lt 2 ] && worst=2
    continue
  }
  json="$(nh_host_secrets "$h" "$platform" 2>/dev/null)" || {
    echo "ERROR: could not evaluate nixhold.secrets for $h — required-secret check skipped"
    [ "$worst" -lt 2 ] && worst=2
    continue
  }
  while IFS=$'\t' read -r n scope; do
    [ -n "$n" ] || continue
    if [ ! -e "$(nh_secret_file "$sdir" "$h" "$n" "$scope")" ]; then
      echo "VIOLATION: $h/$n is required but has no ciphertext (run 'nixhold secret edit $h')"
      worst=3
    fi
  done < <(printf '%s' "$json" | jq -r '
    to_entries[] | select(.value.required)
    | [ .key, (.value.scope // "host") ] | @tsv')
done < <(nh_all_hosts)

[ "$worst" -eq 0 ] && echo "OK: all required secrets are provisioned"
exit "$worst"
