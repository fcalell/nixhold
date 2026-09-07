# Rule: no orphan ciphertext, and no pre-fleet-key layout.
#
#   secrets/<name>.age         is declared, fleet-scoped, by at least
#     one host. One file stands for the whole fleet, so nobody would
#     ever notice it going stale.
#   secrets/<host>/<name>.age  has a matching host-scoped
#     `nixhold.secrets.<name>` on that host.
#   secrets/shared/, secrets/hosts/, *.recipients — the shape of the
#     fleet BEFORE the one-fleet-key model: per-host recipient sets and
#     their sidecars. An error with the migration named, not a warning:
#     those files are read by nothing now, and the ciphertexts under
#     them are invisible to the eval that looks for the new paths.
#
# (Filesystem reads on the CLI side are fine; principle 14 governs the
# framework eval, not the lint toolchain.)

sdir="$(nh_worktree_secrets_dir)" || exit 2
worst=0

# The pre-fleet-key layout first: everything below reads the new
# paths, and reporting a dozen "orphans" that are really one migration
# would bury the one line that helps.
legacy=0
for p in "$sdir/shared" "$sdir/hosts"; do
  [ -d "$p" ] || continue
  echo "VIOLATION: $p is the pre-fleet-key layout — 'git mv $p/<host-or-name> …' per the migration in ARCHITECTURE (Secrets), then 'nixhold secret rekey'"
  legacy=1
  worst=3
done
for f in "$sdir"/*.recipients "$sdir"/*/*.recipients; do
  [ -e "$f" ] || continue
  echo "VIOLATION: $f is a recipient sidecar — recipient sets no longer vary per secret ('git rm' it; see the migration in ARCHITECTURE)"
  legacy=1
  worst=3
done
if [ "$legacy" -eq 1 ]; then
  exit "$worst"
fi

# The declaring side, gathered once. A fleet ciphertext is legitimate
# as long as ONE host declares it.
declared_fleet=""
evalfail=0
declare -A declared_host=()
while IFS= read -r h; do
  [ -n "$h" ] || continue
  platform="$(nh_host_platform "$h")" || {
    evalfail=1
    continue
  }
  json="$(nh_host_secrets "$h" "$platform" 2>/dev/null)" || {
    evalfail=1
    continue
  }
  while IFS=$'\t' read -r n scope; do
    [ -n "$n" ] || continue
    if [ "$scope" = "fleet" ]; then
      declared_fleet="$declared_fleet $n"
    else
      declared_host["$h/$n"]=1
    fi
  done < <(printf '%s' "$json" | jq -r '
    to_entries[] | [ .key, (.value.scope // "host") ] | @tsv')
done < <(nh_all_hosts)

for f in "$sdir"/*.age; do
  [ -e "$f" ] || continue
  n="$(basename "$f" .age)"
  case " $declared_fleet " in
    *" $n "*) continue ;;
  esac
  if [ "$evalfail" -eq 1 ]; then
    echo "ERROR: could not evaluate every host — orphan check skipped for $f"
    [ "$worst" -lt 2 ] && worst=2
    continue
  fi
  echo "VIOLATION: orphan $f (no host declares a fleet-scoped nixhold.secrets.$n)"
  worst=3
done

for f in "$sdir"/*/*.age; do
  [ -e "$f" ] || continue
  h="$(basename "$(dirname "$f")")"
  n="$(basename "$f" .age)"
  if ! nh_host_platform "$h" >/dev/null 2>&1; then
    echo "VIOLATION: orphan $f (host '$h' is not in the fleet — 'nixhold host remove' leaves no such directory)"
    worst=3
    continue
  fi
  # An eval failure must NOT count the host's files as orphans — that
  # would flag every committed secret on a host whose eval breaks for
  # unrelated reasons.
  if [ "$evalfail" -eq 1 ] && [ -z "${declared_host["$h/$n"]:-}" ]; then
    echo "ERROR: could not evaluate nixhold.secrets for every host — orphan check skipped for $f"
    [ "$worst" -lt 2 ] && worst=2
    continue
  fi
  if [ -z "${declared_host["$h/$n"]:-}" ]; then
    echo "VIOLATION: orphan $f (no host-scoped nixhold.secrets.$n declared on $h)"
    worst=3
  fi
done

[ "$worst" -eq 0 ] && echo "OK: no orphan secret files"
exit "$worst"
