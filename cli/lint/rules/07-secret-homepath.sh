# Rule: `homePath` is only meaningful on operator-owned secrets
# (`owner = "user"`) — the HM symlink targets the operator's $HOME.
# Setting it on a service-owned secret is a declaration error.

worst=0
while IFS= read -r h; do
  [ -n "$h" ] || continue
  platform="$(nh_host_platform "$h")" || continue
  json="$(nh_host_eval "$h" "$platform" nixhold.secrets 2>/dev/null)" || continue
  bad="$(printf '%s' "$json" | jq -r 'to_entries[] | select(.value.homePath != null and .value.owner != "user") | .key')"
  [ -n "$bad" ] || continue
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    echo "VIOLATION: $h/$s — homePath set but owner is not \"user\""
    worst=3
  done <<<"$bad"
done < <(nh_all_hosts)

[ "$worst" -eq 0 ] && echo "OK: homePath only on owner=user secrets"
exit "$worst"
