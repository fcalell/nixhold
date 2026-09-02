# Rule: keys/hosts/<host>/ holds host.pub and host.key.age as a pair,
# and both are TRACKED by git. Without the escrow a dead host is only
# re-imageable by rotating its key and rekeying its secrets — repo +
# passphrase stops being a complete operator seat. Without the pubkey
# the escrow is an orphan: a private key nothing is encrypted to, left
# behind by a `host remove` that missed it or a rotation that half
# ran. Presence in the worktree is not enough — an untracked host.pub
# is invisible to dirty-flake eval, so the recipients computation
# silently omits it and the escrow it names is not in the repo at all.
# Warns in dev (legacy hosts predate the escrow), errors under
# --strict (the CI gate).
#
# Limit, stated rather than papered over: age X25519 stanzas carry no
# recipient fingerprint, so nothing here can prove that host.key.age
# decrypts to host.pub's private half without the operator passphrase —
# which lint must never ask for. That invariant is held by construction
# instead: `nh_escrow_host_key` is the single writer of the pair and
# writes both from one private key (host add, host rotate-key, host
# escrow, and host install's backfill all go through it). `nixhold host
# escrow <host>` re-derives the pair from the machine's live key when a
# fleet predates that.

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
  hostdir="${entry%/}"
  h="$(basename "$hostdir")"
  pub="$hostdir/host.pub"
  esc="$hostdir/host.key.age"

  if [ -e "$pub" ] && [ ! -e "$esc" ]; then
    report "$h — host.pub with no host.key.age escrow (run 'nixhold host escrow $h' to capture the live key, or 'nixhold host rotate-key $h')"
    continue
  fi
  if [ -e "$esc" ] && [ ! -e "$pub" ]; then
    report "$h — orphan host.key.age with no host.pub (nothing is encrypted to this key; 'nixhold host remove $h' or restore its pubkey)"
    continue
  fi
  [ -e "$pub" ] || continue

  for f in "$pub" "$esc"; do
    if ! is_tracked "$f"; then
      report "$h — ${f#"$root"/} exists but is not tracked by git ('git add' it: an untracked recipient is invisible to eval, and an uncommitted escrow is not in the repo)"
    fi
  done
done

if [ "$problems" -eq 0 ]; then
  echo "OK: every host key is committed as a tracked host.pub + host.key.age pair"
fi
exit "$worst"
