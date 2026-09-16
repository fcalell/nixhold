# nixhold status [<name>] [--fleet]
#
# Reads declared services, their expose endpoints and the secret
# manifest from the fleet eval, plus ONE live line for a single host:
# the state of its nixhold-* provisioning units and of the
# `nixhold.checks` the fleet declares (lib/provision.sh), because that
# is the one runtime fact the declarations cannot answer — whether the
# machine reached what it declares. The verb never prompts, so a
# darwin check whose daemon only root may list is a word on that line
# rather than a password prompt. Everything else runtime lives in
# `nixhold logs` and `systemctl status`, and
# `--fleet` stays declaration-only. No <name> means this machine.

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
  local machine
  machine="$(nh_host_machine "$host")"
  [ -z "$machine" ] || printf '  guest of: %s  (deploys with it)\n' "$machine"
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
  echo
  printf '  revision: %s\n' "$(nh_status_revision "$host" "$platform")"
  printf '  provisioning: %s\n' "$(nh_status_provisioning "$host" "$platform")"
}

# nh_status_target <host> <platform> — where the live lines read the
# host: "local" for this machine (and for a Mac, which is read on
# itself or not at all), else the operator user at the deploy address,
# pinned to the committed host key when connecting. Non-zero when a
# remote host has no address yet.
nh_status_target() {
  local host="$1" platform="$2" user addr
  if [ "$(nh_deploy_self)" = "$host" ] || [ "$platform" != "nixos" ]; then
    printf 'local'
    return 0
  fi
  user="$(nh_host_eval "$host" nixos nixhold.identity.username 2>/dev/null | jq -r '.')" || user=""
  addr="$(nh_deploy_addr "$host")" || addr=""
  [ -n "$user" ] && [ -n "$addr" ] || return 1
  printf '%s@%s' "$user" "$addr"
}

# nh_status_revision <host> <platform> — the commit the running
# generation was built from (ARCHITECTURE "Where a host is built"):
# `system.configurationRevision`, as the host's own version tool
# prints it. A host that is down, or a Mac read from elsewhere, is a
# word here.
nh_status_revision() {
  local host="$1" platform="$2" target cmd out=""
  case "$platform" in
    nixos) cmd="nixos-version --configuration-revision" ;;
    darwin) cmd="darwin-version --configuration-revision" ;;
    *) return 0 ;;
  esac
  target="$(nh_status_target "$host" "$platform")" || {
    printf 'unreachable (no address for %s yet)' "$host"
    return 0
  }
  if [ "$target" = "local" ]; then
    if [ "$platform" = "darwin" ] && [ "$(uname -s)" != "Darwin" ]; then
      printf 'read it on %s itself' "$host"
      return 0
    fi
    out="$(sh -c "$cmd" 2>/dev/null)" || out=""
  else
    out="$(nh_ssh "$target" --host "$host" -- "$cmd" </dev/null 2>/dev/null)" || out=""
  fi
  case "$out" in
    "" | unknown* | *unknown) printf 'unknown (built before this nixhold, or from a dirty tree)' ;;
    *) printf '%s' "$out" ;;
  esac
}

# nh_status_provisioning <host> <platform> — the live line. The
# connection is deploy's: the operator user at the deploy address,
# pinned to the committed host key. A host that is down is a word
# here, never a failure of the verb.
nh_status_provisioning() {
  local host="$1" platform="$2" local_host=0 target="" state="" rc=0
  target="$(nh_status_target "$host" "$platform")" || {
    printf 'unreachable (no address for %s yet)' "$host"
    return 0
  }
  if [ "$target" = "local" ]; then
    local_host=1
    target=""
  fi
  state="$(nh_provision_state "$host" "$platform" "$local_host" "$target")" || rc=$?
  case "$rc" in
    0) printf '%s' "$state" | awk 'NR > 1 { printf "\n                " } { printf "%s", $0 }' ;;
    2) printf 'unreachable' ;;
    3) printf 'no user session yet (units run at the first login)' ;;
    4) printf 'read it on %s itself (launchd)' "$host" ;;
    5) printf 'unreadable (%s)' "$(tr '\n' ' ' <"$(nh_provision_err)")" ;;
    *) printf '?' ;;
  esac
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
# services column: its plan is `nixhold status <name>`. A guest is
# marked with its machine in the last column.
nh_status_row() {
  local host="$1" platform="$2" services_json secrets_json services secrets missing sdir name note=""
  sdir="$(nh_worktree_secrets_dir)" || return 1
  local machine
  machine="$(nh_host_machine "$host")"
  [ -z "$machine" ] || note="guest of $machine"
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
  printf '%-16s %-8s %-9s %-8s %s%s\n' "$host" "$platform" "$services" "$secrets" \
    "$([ "$missing" -eq 0 ] || printf '%s missing  ' "$missing")" "$note"
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
