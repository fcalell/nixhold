# Provisioning units (ARCHITECTURE "Provisioning"): the live state of
# a host's nixhold-* units, the operator's checkouts in the user
# manager and the fleet's `nixhold.checks` in the system one. One
# read, shared by `status` (its one live line) and `deploy` (after
# activation): activation succeeding says the closure is in place, not
# that what it declares has been reached, and a check says whether
# what it declares works.

# nh_provision_err — the file the last read's stderr landed in, for a
# caller that has to report rc 5. A file, not a variable: every caller
# reads the state through a command substitution, so a subshell is
# where the text is produced. /dev/null when there is no scratch root
# to hold it, so both ends stay a plain redirect.
nh_provision_err() {
  local root
  root="$(nh_tmp_root)" || {
    printf '/dev/null'
    return 0
  }
  printf '%s' "$root/provision.err"
}

# nh_provision_state <name> <platform> <local:0|1> [<target>]
#                    [<sudo-ok:0|1>] — one word or line per unit on
# stdout: "ok", or "<unit> failed|retrying|running" lines. Non-zero:
# 2 unreachable, 3 no user session on the host (its user manager has
# never been started), 4 a darwin host read from elsewhere (launchd is
# only readable on the Mac itself), 5 anything else, with what
# systemctl said in nh_provision_err.
#
# Every host runs provisioning units in two managers: the operator's
# checkouts in the user one, the fleet's `nixhold.checks` in the
# system one (ARCHITECTURE "Provisioning"). Both are read into one
# result, so both verbs say ok/failed/retrying about either. On NixOS
# reading a system unit needs no root; on darwin the checks are
# launchd daemons and only root is shown the system domain, which is
# what <sudo-ok> answers: `deploy` has just elevated on this terminal
# and passes 1, `status` never prompts and prints "checks: needs
# sudo" when sudo refuses.
#
# NixOS: `systemctl --user` on the operator's manager, which a seat
# has running and an ssh login starts. Parsed here rather than on the
# host, so each remote command stays a plain word list.
nh_provision_state() {
  local name="$1" platform="$2" local_host="$3" target="${4:-}" sudo_ok="${5:-0}"
  local raw="" checks="" rc=0 errf
  errf="$(nh_provision_err)"
  case "$platform" in
    nixos)
      # One string, quotes included: the remote side is the operator's
      # login shell, and an unquoted `nixhold-*` is a glob there.
      local cmd="systemctl --user list-units --all --plain --no-legend 'nixhold-*'"
      if [ "$local_host" -eq 1 ]; then
        raw="$(sh -c "$cmd" 2>"$errf")" || rc=$?
      else
        raw="$(nh_ssh "$target" --host "$name" -- "$cmd" </dev/null 2>"$errf")" || rc=$?
      fi
      case "$rc" in
        0) ;;
        255) return 2 ;;
        *)
          # Only "no manager to talk to" is the host waiting for its
          # operator to log in; every other failure is a failure and
          # says so in its own words. The checks wait for that session
          # too: a host read over ssh has one.
          grep -q 'Failed to connect to bus' "$errf" 2>/dev/null || return 5
          return 3
          ;;
      esac
      cmd="systemctl list-units --all --plain --no-legend 'nixhold-check-*'"
      if [ "$local_host" -eq 1 ]; then
        checks="$(sh -c "$cmd" 2>"$errf")" || rc=$?
      else
        checks="$(nh_ssh "$target" --host "$name" -- "$cmd" </dev/null 2>"$errf")" || rc=$?
      fi
      case "$rc" in
        0) ;;
        255) return 2 ;;
        *) return 5 ;;
      esac
      # UNIT LOAD ACTIVE SUB …: failed, auto-restart (a retry in
      # progress) and running (the clone itself, or a check still
      # deciding) are the states worth a word; inactive is done,
      # condition-skipped, or a check that passed.
      printf '%s\n%s\n' "$raw" "$checks" | awk '
        $3 == "failed" { print $1 " failed" }
        $4 == "auto-restart" { print $1 " retrying" }
        $4 == "running" { print $1 " running" }
      ' | nh_provision_words
      ;;
    darwin)
      [ "$(uname -s)" = "Darwin" ] || return 4
      # PID STATUS LABEL: a KeepAlive job whose last exit was
      # non-zero is being retried; one with a PID is running. The
      # agents are the operator's own, the daemons carry the checks.
      # shellcheck disable=SC2016 # an awk program, not a shell one
      local parse='
        $3 ~ /nixhold-/ && $1 != "-" { print $3 " running"; next }
        $3 ~ /nixhold-/ && $2 != 0 { print $3 " retrying" }
      '
      local -a asroot=(sudo -n)
      [ "$sudo_ok" -eq 1 ] && asroot=(sudo)
      local refused=0
      # Whether this Mac carries a check at all is readable without
      # root: nix-darwin writes one world-readable plist per daemon.
      # A fleet that declares none is never asked for a password.
      if compgen -G "/Library/LaunchDaemons/*nixhold-check-*" >/dev/null; then
        checks="$("${asroot[@]}" launchctl list 2>/dev/null)" || refused=1
      fi
      {
        launchctl list 2>/dev/null | awk "$parse"
        printf '%s' "$checks" | awk "$parse"
        [ "$refused" -eq 0 ] || printf 'checks: needs sudo\n'
      } | nh_provision_words
      ;;
    *) return 1 ;;
  esac
}

# stdin: the per-unit lines; stdout: them, or "ok" when there are none.
nh_provision_words() {
  local lines
  lines="$(cat)"
  if [ -z "$lines" ]; then printf 'ok'; else printf '%s' "$lines"; fi
}

# nh_provision_kick <name> <platform> <local:0|1> [<target>] — restart
# the units on a NixOS host after activation, both managers. A unit
# that spent its start limit (`StartLimitBurst` in
# `StartLimitIntervalSec`) is `failed` for as long as its manager
# lives, and sd-switch only starts what the closure changed — so the
# deploy that fixes a unit's cause is also what has to run it again.
# The checkouts that are done skip on their condition, so this costs
# them a condition check; a check has no condition and is meant to run
# again, which is what makes every deploy re-assert what the fleet
# declares.
#
# `start --all GLOB` because the units are pulled in by their target
# and so are in memory; whether one then fails is the report's to say,
# not this. Best-effort: a machine that cannot be kicked is one the
# report is about to describe.
#
# The checks are system units, so starting them is root's. Locally
# sudo asks on the terminal the operator ran the verb from (the
# activation just before it has usually cached the timestamp); on a
# remote host it is the CLI's own escalation ("Sudo asks"), which
# prompts once per process: a second prompt after the one
# `nixos-rebuild --ask-elevate-password` owns, since that one is a
# getpass inside nixos-rebuild whose answer never reaches here.
nh_provision_kick() {
  local name="$1" platform="$2" local_host="$3" target="${4:-}" declared=""
  [ "$platform" = "nixos" ] || return 0
  local kick="systemctl --user reset-failed 'nixhold-*'; systemctl --user start --all 'nixhold-*'"
  # The user kick, and in the same breath the checks this host
  # carries: a fleet that declares none must not be asked for a
  # password on every deploy.
  local probe="{ $kick; } >/dev/null 2>&1; systemctl list-units --all --plain --no-legend 'nixhold-check-*'"
  local checks="nh_rsudo systemctl reset-failed 'nixhold-check-*'; nh_rsudo systemctl start --all 'nixhold-check-*'"
  if [ "$local_host" -eq 1 ]; then
    declared="$(sh -c "$probe" 2>/dev/null)" || declared=""
    [ -n "$declared" ] || return 0
    sh -c "$(nh_sudo_preamble_local)
$checks" >/dev/null 2>&1 || true
  else
    declared="$(nh_ssh "$target" --host "$name" -- "$probe" </dev/null 2>/dev/null)" || declared=""
    [ -n "$declared" ] || return 0
    nh_ssh_sudo "$target" --host "$name" -- "$checks" </dev/null >/dev/null 2>&1 || true
  fi
}

# nh_provision_report <name> <platform> <local:0|1> [<target>]
#                     [<sudo-ok:0|1>] — the deploy-side print: ok, or
# one line per unit that has not reached its state, with where the
# detail is. A unit still running is work in progress, not a warning;
# only `failed` and `retrying` are.
nh_provision_report() {
  local name="$1" platform="$2" state="" rc=0
  state="$(nh_provision_state "$@")" || rc=$?
  case "$rc" in
    0) ;;
    2)
      nh_warn "provisioning: $name unreachable after activation — 'nixhold status $name' reads it later"
      return 0
      ;;
    3)
      nh_info "provisioning: no user session on $name yet — its units run at the operator's first login"
      return 0
      ;;
    5)
      nh_warn "provisioning: could not read the units on $name: $(tr '\n' ' ' <"$(nh_provision_err)")"
      return 0
      ;;
    *) return 0 ;;
  esac
  if [ "$state" = "ok" ]; then
    nh_ok "provisioning: ok"
    return 0
  fi
  local line troubled=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      *" running") nh_info "provisioning: $line" ;;
      *)
        troubled=1
        nh_warn "provisioning: $line"
        ;;
    esac
  done <<<"$state"
  [ "$troubled" -eq 1 ] || return 0
  case "$platform" in
    nixos) nh_info "detail: journalctl --user -u <unit> on $name" ;;
    darwin) nh_info "detail: log show --predicate 'subsystem == \"com.apple.launchd\"' --last 1h | grep nixhold-" ;;
  esac
}
