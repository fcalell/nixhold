# Provisioning units (ARCHITECTURE "Provisioning"): the live state of
# a host's nixhold-* units. One read, shared by `status` (its one live
# line) and `deploy` (after activation): activation succeeding says
# the closure is in place, not that what it declares has been reached.

# nh_provision_state <name> <platform> <local:0|1> [<target>] — one
# word or line per unit on stdout: "ok", or "<unit> failed|retrying|
# running" lines. Non-zero: 2 unreachable, 3 no user session on the
# host (its user manager has never been started), 4 a darwin host
# read from elsewhere (launchd is only readable on the Mac itself).
#
# NixOS: `systemctl --user` on the operator's manager, which a seat
# has running and an ssh login starts. Parsed here rather than on the
# host, so the remote command stays a plain word list.
nh_provision_state() {
  local name="$1" platform="$2" local_host="$3" target="${4:-}" raw="" rc=0
  case "$platform" in
    nixos)
      local -a cmd=(systemctl --user list-units --all --plain --no-legend 'nixhold-*')
      if [ "$local_host" -eq 1 ]; then
        raw="$("${cmd[@]}" 2>/dev/null)" || rc=$?
      else
        raw="$(nh_ssh "$target" --host "$name" -- "${cmd[*]}" </dev/null 2>/dev/null)" || rc=$?
      fi
      case "$rc" in
        0) ;;
        255) return 2 ;;
        *) return 3 ;;
      esac
      # UNIT LOAD ACTIVE SUB …: failed, auto-restart (a retry in
      # progress) and running (the clone itself) are the states worth a
      # word; inactive is done or condition-skipped.
      printf '%s\n' "$raw" | awk '
        $3 == "failed" { print $1 " failed" }
        $4 == "auto-restart" { print $1 " retrying" }
        $4 == "running" { print $1 " running" }
      ' | nh_provision_words
      ;;
    darwin)
      [ "$(uname -s)" = "Darwin" ] || return 4
      # PID STATUS LABEL: a KeepAlive agent whose last exit was
      # non-zero is being retried; one with a PID is running.
      launchctl list 2>/dev/null | awk '
        $3 ~ /nixhold-/ && $1 != "-" { print $3 " running"; next }
        $3 ~ /nixhold-/ && $2 != 0 { print $3 " retrying" }
      ' | nh_provision_words
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

# nh_provision_report <name> <platform> <local:0|1> [<target>] — the
# deploy-side print: ok, or one warning per unit that has not reached
# its state, with where the detail is.
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
    *) return 0 ;;
  esac
  if [ "$state" = "ok" ]; then
    nh_ok "provisioning: ok"
    return 0
  fi
  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    nh_warn "provisioning: $line"
  done <<<"$state"
  case "$platform" in
    nixos) nh_info "detail: journalctl --user -u <unit> on $name" ;;
    darwin) nh_info "detail: log show --predicate 'subsystem == \"com.apple.launchd\"' --last 1h | grep nixhold-" ;;
  esac
}
