# nixhold lint [--strict]
#
# Runs every script under $NIXHOLD_LIB_ROOT/lint/rules/*.sh and
# aggregates results. Each rule prints `OK: <msg>` or
# `VIOLATION: <msg>` and exits 0 / 3. The runner exits with the
# worst code seen. --strict promotes warnings to errors (rules
# read $NIXHOLD_LINT_STRICT internally).

cmd_lint() {
  local strict=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --strict) strict=1; shift ;;
      -h | --help) echo "Usage: nixhold lint [--strict]"; return 0 ;;
      *) nh_err "unknown arg: $1"; return 1 ;;
    esac
  done
  export NIXHOLD_LINT_STRICT="$strict"

  local rules_dir="$NIXHOLD_LIB_ROOT/lint/rules"
  if [ ! -d "$rules_dir" ]; then
    nh_err "no rules dir at $rules_dir"
    return 2
  fi

  local worst=0 rc
  for rule in "$rules_dir"/*.sh; do
    [ -e "$rule" ] || continue
    # Run in a subshell; `|| rc=$?` captures the rule's exit code
    # without `set -e` aborting and without the `! (...)` negation
    # swallowing it (which made the whole runner always exit 0).
    rc=0
    ( . "$rule" ) || rc=$?
    if [ "$rc" -gt "$worst" ]; then worst="$rc"; fi
  done

  if [ "$worst" -eq 0 ]; then
    nh_ok "all lint rules passed"
  fi
  return "$worst"
}
