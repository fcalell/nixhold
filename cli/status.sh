# nixhold status [<name>] [--fleet]
#
# Reads declared services, their expose endpoints and the secret
# manifest from the fleet eval. Declaration-side only — no live SSH
# probes; runtime truth lives in `nixhold logs` and `systemctl
# status`. No <name> means this machine.

cmd_status() {
  local host="" fleet_view=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --fleet) fleet_view=1; shift ;;
      -h | --help) echo "Usage: nixhold status [<name>] [--fleet]"; return 0 ;;
      -*) nh_err "unknown flag: $1"; return 1 ;;
      *) if [ -z "$host" ]; then host="$1"; shift; else nh_err "extra arg: $1"; return 1; fi ;;
    esac
  done

  if [ "$fleet_view" -eq 1 ]; then
    nh_status_fleet
    return $?
  fi

  if [ -z "$host" ]; then
    host="$(nh_hostname)"
    if ! nh_host_platform "$host" >/dev/null 2>&1; then
      if nh_tty; then
        host="$(nh_pick_host "Status of which host?")" || return 1
      else
        nh_err "this machine ('$host') is not a fleet host — expected: nixhold status <name>"
        return 1
      fi
    fi
  fi
  nh_status_host "$host"
}

nh_status_host() {
  local host="$1" platform rc=0 services_json secrets_json sdir
  platform="$(nh_host_platform "$host")" || rc=$?
  case "$rc" in
    0) ;;
    1)
      nh_err "host '$host' is not in this fleet — 'nixhold status --fleet' lists the roster"
      return 1
      ;;
    *) return 1 ;;
  esac
  sdir="$(nh_worktree_secrets_dir)" || return 2

  if [ "$platform" = "android" ]; then
    nh_status_android "$host"
    return $?
  fi

  if ! services_json="$(nh_host_eval "$host" "$platform" nixhold.services)"; then
    nh_err "host '$host' ($platform) does not evaluate — see the error above"
    return 1
  fi
  if ! secrets_json="$(nh_host_secrets "$host" "$platform")"; then
    nh_err "host '$host' ($platform) does not evaluate — see the error above"
    return 1
  fi

  echo "HOST: $host ($platform, $(nh_host_arch "$host"))"
  printf '  networks: %s\n' "$(nh_host_field "$host" networks | jq -r 'join(", ")')"
  echo
  printf '  services:\n'
  printf '%s' "$services_json" | jq -r '
    to_entries[]
    | "    \(.key)\t\(if (.value.enable // false) then "enabled" else "disabled" end)"
  '
  echo
  printf '  endpoints:\n'
  printf '%s' "$services_json" | jq -r '
    to_entries[]
    | select(.value.enable // false)
    | .key as $svc
    | ((.value.expose // {}) | to_entries[])
    | [ "\($svc)/\(.key)", (.value.network // "localhost"), (.value.subdomain // "-"), (.value.pathPrefix // "") ]
    | @tsv
  ' | awk -F'\t' '{ printf "    %-28s %-12s %-20s %s\n", $1, $2, $3, $4 }'
  echo
  # Category and scope are what tell the operator whether a missing
  # secret is theirs to write at all: `nixhold secret list` is the
  # full per-secret view, this is the one-glance summary.
  printf '  secrets:\n'
  printf '%s' "$secrets_json" | jq -r '
    to_entries | sort_by((.value.category // "operator"), .key)[]
    | [ .key, (.value.category // "operator"), (.value.scope // "host"),
        (if .value.required then "required" else "optional" end),
        (.value.description // "") ]
    | @tsv
  ' | while IFS=$'\t' read -r name category scope req desc; do
    local state="missing"
    [ -e "$(nh_secret_file "$sdir" "$host" "$name" "$scope")" ] && state="present"
    printf '    %-24s %-12s %-6s %-8s %-8s %s\n' "$name" "$category" "$scope" "$state" "$req" "$desc"
  done
}

# nh_status_android <host> — an Android host has no services: what it
# declares is its plan, shown eval-side (no APK is fetched).
nh_status_android() {
  local host="$1" summary secrets_json sdir
  sdir="$(nh_worktree_secrets_dir)" || return 2
  if ! summary="$(nh_host_eval "$host" android android.summary)" \
    || ! secrets_json="$(nh_host_secrets "$host" android)"; then
    nh_err "host '$host' (android) does not evaluate — see the error above"
    return 1
  fi
  echo "HOST: $host (android, $(nh_host_arch "$host"))"
  printf '  networks: %s\n' "$(nh_host_field "$host" networks | jq -r 'join(", ")')"
  printf '  device_name: %s\n' "$(printf '%s' "$summary" | jq -r '.hostName')"
  local serial
  serial="$(nh_host_field "$host" serial)"
  printf '  reach: %s\n' "${serial:+usb serial $serial}${serial:-$(nh_deploy_addr "$host" || true)}"
  echo
  printf '  packages:\n'
  printf '%s' "$summary" | jq -r '.apks[] | "    \(.)"'
  printf '  removed:\n'
  printf '%s' "$summary" | jq -r '.removedPackages[] | "    \(.)"'
  printf '  settings:\n'
  printf '%s' "$summary" | jq -r '.settings | to_entries[] | .key as $ns | .value | to_entries[] | "    \($ns) \(.key) = \(.value)"'
  printf '  launcher: %s\n' "$(printf '%s' "$summary" | jq -r '.launcher // "-"')"
  printf '  device owner: %s\n' "$(printf '%s' "$summary" | jq -r '.deviceOwner // "-"')"
  echo
  printf '  secrets:\n'
  printf '%s' "$secrets_json" | jq -r '
    to_entries[]
    | [ .key, (.value.category // "operator"), (.value.scope // "host"),
        (if .value.required then "required" else "optional" end),
        (.value.description // "") ]
    | @tsv
  ' | while IFS=$'\t' read -r name category scope req desc; do
    local state="missing"
    [ -e "$(nh_secret_file "$sdir" "$host" "$name" "$scope")" ] && state="present"
    printf '    %-24s %-12s %-6s %-8s %-8s %s\n' "$name" "$category" "$scope" "$state" "$req" "$desc"
  done
}

# One table row. A host that fails to evaluate is marked and the walk
# continues — one broken host must not hide the rest of the fleet —
# but the verb's exit status remembers it. An Android host has no
# services column: its plan is `nixhold status <name>`.
nh_status_row() {
  local host="$1" platform="$2" services_json secrets_json services secrets missing sdir name
  sdir="$(nh_worktree_secrets_dir)" || return 1
  if [ "$platform" = "android" ]; then
    services_json="{}"
    services="-"
  elif ! services_json="$(nh_host_eval "$host" "$platform" nixhold.services 2>/dev/null)"; then
    printf '%-16s %-8s %-9s %-8s %s\n' "$host" "$platform" eval-err eval-err ""
    return 1
  else
    services="$(printf '%s' "$services_json" | jq '[.[] | select(.enable // false)] | length')"
  fi
  if ! secrets_json="$(nh_host_secrets "$host" "$platform" 2>/dev/null)"; then
    printf '%-16s %-8s %-9s %-8s %s\n' "$host" "$platform" "$services" eval-err ""
    return 1
  fi
  secrets="$(printf '%s' "$secrets_json" | jq 'length')"
  missing=0
  local scope
  while IFS=$'\t' read -r name scope; do
    [ -n "$name" ] || continue
    [ -e "$(nh_secret_file "$sdir" "$host" "$name" "$scope")" ] || missing=$((missing + 1))
  done < <(printf '%s' "$secrets_json" | jq -r '
    to_entries[] | [ .key, (.value.scope // "host") ] | @tsv')
  printf '%-16s %-8s %-9s %-8s %s\n' "$host" "$platform" "$services" "$secrets" "$([ "$missing" -eq 0 ] || printf '%s missing' "$missing")"
}

nh_status_fleet() {
  local rc=0 line hosts
  hosts="$(nh_hosts)" || return 1
  printf '%-16s %-8s %-9s %-8s %s\n' HOST PLATFORM SERVICES SECRETS ""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    nh_status_row "${line%% *}" "${line##* }" || rc=1
  done <<<"$hosts"
  return "$rc"
}
