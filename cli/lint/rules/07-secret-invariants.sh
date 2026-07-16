# Rule: per-secret declaration invariants. These mirror the module
# assertions in modules/secrets/default.nix — assertions only fire on
# a toplevel build, which hosts blocked from building (e.g. missing
# facter report) never reach; lint checks the same invariants from a
# plain option eval.
#   - homePath only on operator-owned secrets (owner = "user") — the
#     HM symlink targets the operator's $HOME.
#   - sshKey only on operator-owned secrets.
#   - sshIdentity implies sshKey (violated only by an explicit
#     sshKey = false; the module defaults it on).
#   - at most one sshIdentity secret per host (it becomes the single
#     IdentityFile for fleet-peer ssh).

worst=0
while IFS= read -r h; do
  [ -n "$h" ] || continue
  platform="$(nh_host_platform "$h")" || {
    echo "ERROR: could not resolve platform for $h — secret invariants check skipped"
    [ "$worst" -lt 2 ] && worst=2
    continue
  }
  json="$(nh_host_eval "$h" "$platform" nixhold.secrets 2>/dev/null)" || {
    echo "ERROR: could not evaluate nixhold.secrets for $h — secret invariants check skipped"
    [ "$worst" -lt 2 ] && worst=2
    continue
  }

  bad="$(printf '%s' "$json" | jq -r '
    to_entries[]
    | . as $e
    | [
        (select($e.value.homePath != null and $e.value.owner != "user")
          | "\($e.key) — homePath set but owner is not \"user\""),
        (select($e.value.sshKey and $e.value.owner != "user")
          | "\($e.key) — sshKey set but owner is not \"user\""),
        (select($e.value.sshIdentity and ($e.value.sshKey | not))
          | "\($e.key) — sshIdentity with explicit sshKey = false")
      ][]')"
  if [ -n "$bad" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      echo "VIOLATION: $h/$line"
      worst=3
    done <<<"$bad"
  fi

  idcount="$(printf '%s' "$json" | jq '[.[] | select(.sshIdentity)] | length')"
  if [ "$idcount" -gt 1 ]; then
    echo "VIOLATION: $h — $idcount secrets set sshIdentity = true (at most one per host)"
    worst=3
  fi
done < <(nh_all_hosts)

[ "$worst" -eq 0 ] && echo "OK: secret declaration invariants hold"
exit "$worst"
