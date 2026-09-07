# Rule: every path in `nixhold.layout` (defaulted or overridden)
# exists in the operator's working tree. The framework never reads
# these at eval time, so a stale override fails late and obscurely —
# in the CLI verb that tries to write there. Checked against the
# worktree-re-rooted path, not the store path the option evaluates to:
# the store copy always exists (it is a copy of the flake), so testing
# it would prove nothing.
#
# Also: `layout.repoUrl` set with no secrets/identity.age means the
# installer ISO has no credential to clone or push the fleet repo with
# — a warning in both modes, since the clone key is only needed once
# an ISO is built.

worst=0

hosts="$(nh_all_hosts)"
if [ -z "$hosts" ]; then
  echo "OK: no hosts to probe layout from"
  exit 0
fi

# File- and dir-valued keys only; `repoUrl` is a string, not a path.
# `hostsDir`, `modulesDir` and `profilesDir` are exempt: they are
# scaffold targets — `host add` and `service new` mkdir -p them on
# demand (even under a stale override, so nothing fails late) — and a
# fleet that authors no fleet modules/profiles legitimately has no
# such dir.
for key in secrets hostsFile keysDir ageRecipient; do
  # stderr is NOT suppressed: exit 3 means the value resolves into
  # another flake input, and the helper's message names it.
  p="$(nh_worktree_layout_file "$key")" || {
    rc=$?
    if [ "$rc" -eq 3 ]; then
      echo "VIOLATION: nixhold.layout.$key resolves outside the fleet checkout (see the error above) — the CLI reads and writes only inside it"
      worst=3
    else
      echo "ERROR: could not probe nixhold.layout.$key — existence check skipped"
      [ "$worst" -lt 2 ] && worst=2
    fi
    continue
  }
  if [ ! -e "$p" ]; then
    echo "VIOLATION: nixhold.layout.$key resolves to $p, which does not exist"
    worst=3
  fi
done

# `ageIdentityWrapped` is nullOr path: a fleet whose operator seat is a
# FIDO2 token commits no keys/operator.age and the option evaluates to
# null. Null and "could not probe" are the same non-zero from the
# helper, so this is a skip rather than an error — the four keys above
# already fail loudly on an eval that is broken, and rule 04 is what
# checks that SOME route into the ciphertexts exists.
p="$(nh_worktree_layout_file ageIdentityWrapped 2>/dev/null)" || p=""
if [ -n "$p" ] && [ ! -e "$p" ]; then
  echo "VIOLATION: nixhold.layout.ageIdentityWrapped resolves to $p, which does not exist (set it to null if this fleet has no passphrase identity)"
  worst=3
fi

sdir="$(nh_worktree_secrets_dir)" || {
  [ "$worst" -lt 2 ] && worst=2
  exit "$worst"
}
repo="$(nh_layout repoUrl 2>/dev/null | jq -r '. // empty')"
if [ -n "$repo" ] && [ ! -e "$sdir/identity.age" ]; then
  echo "WARNING: layout.repoUrl is set ($repo) but $sdir/identity.age is missing — the ISO cannot clone the fleet repo, since the fleet's own identity key is what it clones with ('nixhold secret edit <host> identity' provisions it)"
fi

[ "$worst" -eq 0 ] && echo "OK: every layout path exists in the worktree"
exit "$worst"
