# nixhold logs [<host>] [<service>] [--lines N] [--since <when>] [--follow]
# Thin wrapper around `ssh <addr> journalctl -u <unit>`. An omitted
# host or unit is picked: NixOS hosts, then the host's enabled
# nixhold services (any unit name still works as an argument).

cmd_logs() {
  local host="" service="" lines="" since="" follow=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --lines) lines="$2"; shift 2 ;;
      --since) since="$2"; shift 2 ;;
      --follow|-f) follow=1; shift ;;
      -h | --help) echo "Usage: nixhold logs [<host>] [<service>] [--lines N] [--since <when>] [--follow]"; return 0 ;;
      -*) nh_err "unknown flag: $1"; return 1 ;;
      *)
        if [ -z "$host" ]; then host="$1"
        elif [ -z "$service" ]; then service="$1"
        else nh_err "extra arg: $1"; return 1
        fi
        shift
        ;;
    esac
  done
  if { [ -z "$host" ] || [ -z "$service" ]; } && ! nh_tty; then
    nh_err "expected: nixhold logs <host> <service>"
    return 1
  fi
  if [ -z "$host" ]; then
    host="$(nh_pick_host "Logs of which host?" nixos)" || return 1
  fi
  if [ "$(nh_host_platform "$host" 2>/dev/null || true)" != "nixos" ]; then
    nh_err "'$host' is not a NixOS host in this fleet — journald logs are read over ssh from NixOS hosts"
    return 1
  fi
  if [ -z "$service" ]; then
    local enabled=() line
    while IFS= read -r line; do
      [ -n "$line" ] && enabled+=("$line")
    done < <(nh_host_eval "$host" nixos nixhold.services | jq -r 'to_entries[] | select(.value.enable // false) | .key')
    if [ "${#enabled[@]}" -eq 0 ]; then
      nh_err "no enabled nixhold service on $host — name a unit: nixhold logs $host <unit>"
      return 1
    fi
    service="$(gum choose --header "Which unit on $host?" "${enabled[@]}")" || return 1
  fi

  local addr
  addr="$(nh_deploy_addr "$host")"
  [ -z "$addr" ] && { nh_err "could not resolve address for $host"; return 1; }

  # SSH as the operator (the hardened openssh preset plants no root
  # authorized key) and read the journal via sudo.
  local user
  user="$(nh_host_eval "$host" nixos "nixhold.identity.username" | jq -r '.')"
  [ -z "$user" ] && { nh_err "could not resolve operator username for $host"; return 1; }

  local args=(sudo journalctl -u "$service")
  [ -n "$lines" ] && args+=(-n "$lines")
  [ -n "$since" ] && args+=(--since "$since")
  [ "$follow" -eq 1 ] && args+=(-f)

  # ssh joins argv with spaces for the remote shell — re-quote so
  # values like `--since "2 hours ago"` survive.
  nh_ssh "$user@$addr" --host "$host" -- "$(printf '%q ' "${args[@]}")"
}
