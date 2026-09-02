# Rule: every path in `nixhold.layout` (defaulted or overridden)
# exists in the operator's working tree. The framework never reads
# these at eval time, so a stale override fails late and obscurely —
# in the CLI verb that tries to write there. Checked against the
# worktree-re-rooted path, not the store path the option evaluates to:
# the store copy always exists (it is a copy of the flake), so testing
# it would prove nothing.
#
# Also: `layout.repoUrl` set with no keys/repo.key.age means the
# installer ISO cannot clone or push the fleet repo — a warning in
# both modes, since the deploy key is only needed once an ISO is
# built.

worst=0

hosts="$(nh_all_hosts)"
if [ -z "$hosts" ]; then
  echo "OK: no hosts to probe layout from"
  exit 0
fi

# File- and dir-valued keys only; `repoUrl` is a string, not a path.
# `modulesDir` and `profilesDir` are exempt: they are scaffold targets
# only — nothing reads them, and `service new` / `profile new` mkdir -p
# them on demand (even under a stale override, so nothing fails late) —
# and a fleet that authors no fleet modules/profiles legitimately has
# no such dir.
for key in secrets hostsFile keysDir ageRecipient ageIdentityWrapped; do
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

keys_dir="$(nh_worktree_keys_dir)" || {
  [ "$worst" -lt 2 ] && worst=2
  exit "$worst"
}
repo="$(nh_layout repoUrl 2>/dev/null | jq -r '. // empty')"
if [ -n "$repo" ] && [ ! -e "$keys_dir/repo.key.age" ]; then
  echo "WARNING: layout.repoUrl is set ($repo) but $keys_dir/repo.key.age is missing — the ISO cannot clone or push the fleet repo ('nixhold iso' generates and escrows it)"
fi

[ "$worst" -eq 0 ] && echo "OK: every layout path exists in the worktree"
exit "$worst"
