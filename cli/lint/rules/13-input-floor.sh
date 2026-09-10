# Rule 13: the fleet, not nixhold, pins the heavy inputs.
#
# nixhold's root inputs are the base the framework is written
# against. The fleet declares each at its own root and rebinds
# nixhold to it with `inputs.nixhold.inputs.<x>.follows`, so one
# lock — the fleet's — builds every host and `nixhold update` moves
# all of it ("Inputs: who pins what"). Three ways that goes wrong:
#   - not declared: the fleet inherits nixhold's pin for it, silently,
#     and no `nixhold update` ever moves it (warn dev / error strict)
#   - declared, not followed: two copies of one input in the closure,
#     nixhold building on a base the fleet cannot see (error)
#   - followed, but locked older than nixhold's own lock: framework
#     code running on a base it was never written for (warn dev /
#     error strict). Newer is the normal state and the gate's concern.
# nixhold's lock arrives as $NIXHOLD_LOCK — exported by the package
# beside NIXHOLD_LIB_ROOT, the checkout's own when run in-tree.

strict="${NIXHOLD_LINT_STRICT:-0}"
root="$(nh_fleet_root)" || exit 2
fleet_lock="$root/flake.lock"
nixhold_lock="${NIXHOLD_LOCK:-}"

if [ ! -f "$fleet_lock" ]; then
  echo "VIOLATION: no flake.lock at $root — 'nix flake lock' writes it"
  exit 3
fi
if [ -z "$nixhold_lock" ] || [ ! -f "$nixhold_lock" ]; then
  echo "VIOLATION: nixhold's own flake.lock is not at \$NIXHOLD_LOCK (${nixhold_lock:-unset})"
  exit 3
fi

worst=0
problems=0

report() {
  problems=$((problems + 1))
  if [ "$strict" = "1" ]; then
    echo "VIOLATION: $1"
    worst=3
  else
    echo "WARNING: $1"
  fi
}

violation() {
  problems=$((problems + 1))
  echo "VIOLATION: $1"
  worst=3
}

# One line per nixhold root input: "<state> <input> [<fleet input> <fleet date> <floor date>]".
# In a lock, a followed input is an array (the path from the root:
# `["nixpkgs"]`), a locked one a node name (string).
while IFS=' ' read -r state input fleet_name have floor; do
  [ -n "$state" ] || continue
  case "$state" in
    ok) ;;
    missing)
      report "$input — nixhold declares it and the fleet does not, so the fleet inherits nixhold's pin and 'nixhold update' never moves it (declare it at the fleet root with inputs.nixhold.inputs.$input.follows)"
      ;;
    unfollowed)
      violation "$input — declared at the fleet root but nixhold is not pointed at it (inputs.nixhold.inputs.$input.follows = \"$input\"): two copies of one input in the closure"
      ;;
    behind)
      report "$input — the fleet's '$fleet_name' is locked at $have, older than nixhold's own pin ($floor): framework code on a base it was not written for ('nixhold update' moves it)"
      ;;
  esac
done < <(jq -r -n --slurpfile f "$fleet_lock" --slurpfile n "$nixhold_lock" '
  def day: todate | .[0:10];
  ($f[0].nodes) as $fn
  | ($n[0].nodes) as $nn
  | ($fn[$fn.root.inputs.nixhold]) as $held
  | ($nn.root.inputs | keys[]) as $x
  | ($nn[$nn.root.inputs[$x]].locked.lastModified) as $floor
  | ($held.inputs[$x]) as $seen
  | if ($seen | type) == "array" and ($seen | length) == 1 and $fn.root.inputs[$seen[0]] != null then
      ($seen[0]) as $name
      | ($fn[$fn.root.inputs[$name]].locked.lastModified) as $have
      | if $have < $floor then "behind \($x) \($name) \($have | day) \($floor | day)"
        else "ok \($x)" end
    elif $fn.root.inputs[$x] != null then "unfollowed \($x)"
    else "missing \($x)" end')

if [ "$problems" -eq 0 ]; then
  echo "OK: every input nixhold declares is pinned by the fleet, no older than nixhold's own lock"
fi
exit "$worst"
