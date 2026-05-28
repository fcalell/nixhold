# Rule: every host that declares secrets has its SSH host pubkey
# committed as a recipient of each secret (so it can decrypt at
# activation). `nixhold.secrets.<name>.recipients` includes the host
# key only when keys/hosts/<host>/host.pub is committed, so a declared
# secret with fewer than two recipients means the host key (or the
# operator key) is missing.

worst=0
while IFS= read -r h; do
  [ -n "$h" ] || continue
  platform="$(nh_host_platform "$h")" || continue
  json="$(nh_host_eval "$h" "$platform" nixhold.secrets 2>/dev/null)" || continue
  bad="$(printf '%s' "$json" | jq -r 'to_entries[] | select((.value.recipients | length) < 2) | .key')"
  [ -n "$bad" ] || continue
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    echo "VIOLATION: $h/$s — host key not a recipient (commit keys/hosts/$h/host.pub, then 'nixhold secret rekey')"
    worst=3
  done <<<"$bad"
done < <(nh_all_hosts)

[ "$worst" -eq 0 ] && echo "OK: every declared secret includes the host recipient"
exit "$worst"
