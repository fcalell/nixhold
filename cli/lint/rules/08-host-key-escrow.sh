# Rule: every committed keys/hosts/<host>/host.pub has a sibling
# host.key.age escrow (the host SSH private key, encrypted to the
# operator recipient). Without it a dead host is only re-imageable by
# rotating its key and rekeying its secrets — repo + passphrase stops
# being a complete operator seat. Warns in dev (legacy hosts predate
# the escrow), errors under --strict (the CI gate).

keys_dir="$(nh_worktree_keys_dir)" || exit 2
strict="${NIXHOLD_LINT_STRICT:-0}"
worst=0
missing=0

for pub in "$keys_dir"/hosts/*/host.pub; do
  [ -e "$pub" ] || continue
  h="$(basename "$(dirname "$pub")")"
  [ -e "$(dirname "$pub")/host.key.age" ] && continue
  missing=$((missing + 1))
  if [ "$strict" = "1" ]; then
    echo "VIOLATION: $h — host.pub with no host.key.age escrow (run 'nixhold host rotate-key $h')"
    worst=3
  else
    echo "WARNING: $h — host.pub with no host.key.age escrow (run 'nixhold host rotate-key $h')"
  fi
done

[ "$missing" -eq 0 ] && echo "OK: every committed host.pub has its escrow"
exit "$worst"
