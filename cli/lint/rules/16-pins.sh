# Rule: every pin (ARCHITECTURE "Pins") has one declaration across the
# fleet, a file inside the checkout that exists in the worktree and is
# tracked by git, and a file that parses with a `.version`. The
# declaration evaluates with the file absent (that is what lets
# `update` write it), so a missing file otherwise fails late: at the
# first build that forces `value`.

root="$(nh_fleet_root)" || exit 2
worst=0

is_tracked() {
  git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  git -C "$root" ls-files --error-unmatch -- "$1" >/dev/null 2>&1
}

pins="$(nh_fleet_pins)" || {
  echo "VIOLATION: the pins are not declared consistently across hosts (see the error above)"
  exit 3
}
names="$(printf '%s' "$pins" | jq -r 'keys[]')"
if [ -z "$names" ]; then
  echo "OK: no pins declared"
  exit 0
fi

for name in $names; do
  evaluated="$(printf '%s' "$pins" | jq -r --arg n "$name" '.[$n].file')"
  p="$(nh_pin_file "$name" "$evaluated")" || {
    rc=$?
    if [ "$rc" -eq 3 ]; then
      echo "VIOLATION: nixhold.pins.$name.file resolves outside the fleet checkout (see the error above) — the CLI writes only inside it"
      worst=3
    else
      echo "ERROR: could not re-root nixhold.pins.$name.file — its checks are skipped"
      [ "$worst" -lt 2 ] && worst=2
    fi
    continue
  }
  if [ ! -f "$p" ]; then
    echo "VIOLATION: nixhold.pins.$name has no file at $p — 'nixhold update' writes it"
    worst=3
    continue
  fi
  if ! is_tracked "$p"; then
    echo "VIOLATION: ${p#"$root"/} is not tracked by git — nix eval cannot see an untracked file, so the pin $name reads as missing on every host ('git add' it)"
    worst=3
  fi
  v="$(jq -r '.version // empty' "$p" 2>/dev/null)" || v=""
  if [ -z "$v" ]; then
    echo "VIOLATION: $p is not a manifest with a .version (pin $name)"
    worst=3
  fi
done

[ "$worst" -eq 0 ] && echo "OK: every declared pin has a committed manifest with a version"
exit "$worst"
