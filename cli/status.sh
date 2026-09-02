# nixhold status [--host <name>] [--fleet]
#
# Reads declared services / expose / secrets from the fleet
# eval. Declaration-side only — no live SSH probes; runtime
# truth lives in `nixhold logs` and `systemctl status`.

cmd_status() {
  local host="" fleet_view=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --host) host="$2"; shift 2 ;;
      --fleet) fleet_view=1; shift ;;
      -h | --help) echo "Usage: nixhold status [--host <name>] [--fleet]"; return 0 ;;
      *) nh_err "unknown arg: $1"; return 1 ;;
    esac
  done

  if [ "$fleet_view" -eq 1 ]; then
    nh_status_fleet
    return $?
  fi

  if [ -z "$host" ]; then
    host="$(hostname -s 2>/dev/null || hostname)"
  fi
  nh_status_host "$host"
}

# nh_status_hosts <root> <nixos|darwin> — the fleet's roster for one
# platform, taken from the flake's own attribute names. A failure here
# is a broken flake and says so: it must never read as "the fleet has
# no hosts".
nh_status_hosts() {
  local root="$1" platform="$2" set json
  case "$platform" in
    nixos) set="nixosConfigurations" ;;
    darwin) set="darwinConfigurations" ;;
    *) nh_err "unknown platform: $platform"; return 1 ;;
  esac
  if ! json="$(nix eval --json --no-warn-dirty "$root#$set" --apply 'builtins.attrNames')"; then
    nh_err "could not list $set in $root — see the eval error above"
    return 1
  fi
  printf '%s' "$json" | jq -r '.[]?'
}

# nh_status_platform <root> <host> — which configuration set declares
# <host>. Membership comes from the roster, never from "did this host
# evaluate": an eval failure inside a host means a broken host, not a
# missing one, and the two need different messages.
nh_status_platform() {
  local root="$1" host="$2" platform hosts h
  for platform in nixos darwin; do
    hosts="$(nh_status_hosts "$root" "$platform")" || return 2
    for h in $hosts; do
      if [ "$h" = "$host" ]; then
        printf '%s' "$platform"
        return 0
      fi
    done
  done
  return 1
}

nh_status_host() {
  local host="$1" root platform rc=0 services_json secrets_json
  root="$(nh_fleet_root)" || return 1

  platform="$(nh_status_platform "$root" "$host")" || rc=$?
  case "$rc" in
    0) ;;
    1)
      nh_err "host '$host' is not in this fleet — 'nixhold status --fleet' lists the roster"
      return 1
      ;;
    *) return 1 ;;
  esac

  if ! services_json="$(nh_host_eval "$host" "$platform" nixhold.services)"; then
    nh_err "host '$host' ($platform) does not evaluate — see the error above"
    return 1
  fi
  if ! secrets_json="$(nh_host_eval "$host" "$platform" nixhold.secrets)"; then
    nh_err "host '$host' ($platform) does not evaluate — see the error above"
    return 1
  fi

  echo "HOST: $host ($platform)"
  printf '  services:\n'
  printf '%s' "$services_json" | jq -r '
    to_entries[]
    | "    \(.key)\t\(if (.value.enable // false) then "enabled" else "disabled" end)"
  '
  echo
  printf '  secrets:\n'
  printf '%s' "$secrets_json" | jq -r '
    to_entries[]
    | "    \(.key)\t\(.value.description // "")"
  '
}

# One table row. A host that fails to evaluate is marked and the walk
# continues — one broken host must not hide the rest of the fleet —
# but the verb's exit status remembers it.
nh_status_row() {
  local host="$1" platform="$2" services_json secrets_json services secrets
  if ! services_json="$(nh_host_eval "$host" "$platform" nixhold.services)" \
    || ! secrets_json="$(nh_host_eval "$host" "$platform" nixhold.secrets)"; then
    printf '%-16s %-10s %-10s %-10s\n' "$host" "$platform" eval-err eval-err
    return 1
  fi
  services="$(printf '%s' "$services_json" | jq '[.[] | select(.enable // false)] | length')"
  secrets="$(printf '%s' "$secrets_json" | jq 'length')"
  printf '%-16s %-10s %-10s %-10s\n' "$host" "$platform" "$services" "$secrets"
}

nh_status_fleet() {
  local root rc=0 nixos_hosts darwin_hosts h
  root="$(nh_fleet_root)" || return 1
  nixos_hosts="$(nh_status_hosts "$root" nixos)" || return 1
  darwin_hosts="$(nh_status_hosts "$root" darwin)" || return 1

  printf '%-16s %-10s %-10s %-10s\n' HOST PLATFORM SERVICES SECRETS
  for h in $nixos_hosts; do
    nh_status_row "$h" nixos || rc=1
  done
  for h in $darwin_hosts; do
    nh_status_row "$h" darwin || rc=1
  done
  return "$rc"
}
