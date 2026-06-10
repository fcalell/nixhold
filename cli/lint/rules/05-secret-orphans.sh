# Rule: no orphan ciphertext — every secrets/hosts/<host>/<name>.age
# file has a matching `nixhold.secrets.<name>` declaration on that
# host. (Filesystem read on the CLI side is fine; principle 14 governs
# the framework eval, not the lint toolchain.)

sdir="$(nh_worktree_secrets_dir)" || exit 2
worst=0
for f in "$sdir"/hosts/*/*.age; do
  [ -e "$f" ] || continue
  h="$(basename "$(dirname "$f")")"
  n="$(basename "$f" .age)"
  platform="$(nh_host_platform "$h")" || {
    echo "VIOLATION: orphan $f (host '$h' is not in the fleet)"
    worst=3
    continue
  }
  # An eval failure must NOT count the host's files as orphans —
  # that would flag every committed secret on a host whose eval
  # breaks for unrelated reasons.
  json="$(nh_host_eval "$h" "$platform" nixhold.secrets 2>/dev/null)" || {
    echo "ERROR: could not evaluate nixhold.secrets for $h — orphan check skipped for $f"
    [ "$worst" -lt 2 ] && worst=2
    continue
  }
  if ! printf '%s' "$json" | jq -e --arg n "$n" 'has($n)' >/dev/null 2>&1; then
    echo "VIOLATION: orphan $f (no nixhold.secrets.$n declared on $h)"
    worst=3
  fi
done

[ "$worst" -eq 0 ] && echo "OK: no orphan secret files"
exit "$worst"
