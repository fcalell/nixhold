# Rule: keys/hosts/<host>.pub — one tracked SSH pubkey per roster host,
# and no pubkey for a host that is not in the roster.
#
# It is the fleet's known_hosts record: every remote verb pins its
# connection to it, and `modules/fleet/known-hosts.nix` writes it into
# the fleet's ssh config. A missing one means every connection to that
# host is trust-on-first-use; an orphan one means the fleet pins a
# machine it no longer manages. Presence in the worktree is not enough
# — an untracked file is invisible to dirty-flake eval, so the module
# would not see it either.
#
# It is NOT a recipient of anything: host keys stopped being age
# recipients with the fleet key, so a missing pubkey costs verification,
# never decryption. Hence: warns in dev (a host installed before this,
# or adopted from elsewhere), errors under --strict (the CI gate). The
# fix is `nixhold host key <host>`, which records what the machine runs.
#
# The pre-fleet-key layout put this at keys/hosts/<host>/host.pub
# beside an escrowed private half; a directory there is reported with
# the migration rather than read.

keys_dir="$(nh_worktree_keys_dir)" || exit 2
root="$(nh_fleet_root)" || exit 2
strict="${NIXHOLD_LINT_STRICT:-0}"
worst=0
problems=0

is_tracked() {
  git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  git -C "$root" ls-files --error-unmatch -- "$1" >/dev/null 2>&1
}

report() {
  problems=$((problems + 1))
  if [ "$strict" = "1" ]; then
    echo "VIOLATION: $1"
    worst=3
  else
    echo "WARNING: $1"
  fi
}

for entry in "$keys_dir"/hosts/*/; do
  [ -d "$entry" ] || continue
  echo "VIOLATION: ${entry%/} is the pre-fleet-key layout (host.pub + an escrowed host.key.age) — 'git mv ${entry%/}/host.pub ${entry%/}.pub' and 'git rm ${entry%/}/host.key.age'; host keys are not recipients any more"
  worst=3
done

roster=""
while IFS= read -r line; do
  h="${line%% *}"
  platform="${line##* }"
  [ -n "$h" ] || continue
  roster="$roster $h"
  # An Android host runs no sshd: nothing to pin, nothing to record.
  [ "$platform" = "android" ] && continue
  pub="$keys_dir/hosts/$h.pub"
  if [ ! -e "$pub" ]; then
    report "$h — no keys/hosts/$h.pub, so every connection to it is trust-on-first-use ('nixhold host key $h' records the key the machine runs; 'nixhold host install' writes one for a machine it images)"
    continue
  fi
  if ! is_tracked "$pub"; then
    report "$h — ${pub#"$root"/} exists but is not tracked by git ('git add' it: an untracked pubkey is invisible to eval, so the fleet's known_hosts never sees it)"
  fi
done < <(nh_hosts)

for f in "$keys_dir"/hosts/*.pub; do
  [ -e "$f" ] || continue
  h="$(basename "$f" .pub)"
  case " $roster " in
    *" $h "*) continue ;;
  esac
  echo "VIOLATION: orphan $f (no host '$h' in the roster — 'nixhold host remove' deletes it; a renamed host needs the file renamed with it)"
  worst=3
done

if [ "$problems" -eq 0 ] && [ "$worst" -eq 0 ]; then
  echo "OK: every roster host has a tracked keys/hosts/<host>.pub"
fi
exit "$worst"
