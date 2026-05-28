# Rule: every `required = true` secret has ciphertext committed on the
# host that needs it. Replaces the dropped `secret check` verb; the
# fix is `nixhold secret bootstrap <host>`.

sdir="$(nh_worktree_secrets_dir)" || exit 2
worst=0
while IFS= read -r h; do
  [ -n "$h" ] || continue
  platform="$(nh_host_platform "$h")" || continue
  json="$(nh_host_eval "$h" "$platform" nixhold.secrets 2>/dev/null)" || continue
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    if [ ! -e "$sdir/hosts/$h/$n.age" ]; then
      echo "VIOLATION: $h/$n is required but has no ciphertext (run 'nixhold secret bootstrap $h')"
      worst=3
    fi
  done < <(printf '%s' "$json" | jq -r 'to_entries[] | select(.value.required) | .key')
done < <(nh_all_hosts)

[ "$worst" -eq 0 ] && echo "OK: all required secrets are provisioned"
exit "$worst"
