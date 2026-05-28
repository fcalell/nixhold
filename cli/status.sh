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

nh_status_host() {
  local host="$1"
  local platform="" services_json="" secrets_json=""
  if services_json="$(nh_host_eval "$host" nixos nixhold.services 2>/dev/null)"; then
    platform="nixos"
  elif services_json="$(nh_host_eval "$host" darwin nixhold.services 2>/dev/null)"; then
    platform="darwin"
  else
    nh_err "host '$host' not found"
    return 1
  fi
  secrets_json="$(nh_host_eval "$host" "$platform" nixhold.secrets)"

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

nh_status_fleet() {
  local root; root="$(nh_fleet_root)" || return 1
  local nixos_hosts darwin_hosts
  nixos_hosts="$(nix eval --json --no-warn-dirty "$root#nixosConfigurations" --apply 'builtins.attrNames' 2>/dev/null | jq -r '.[]?' || true)"
  darwin_hosts="$(nix eval --json --no-warn-dirty "$root#darwinConfigurations" --apply 'builtins.attrNames' 2>/dev/null | jq -r '.[]?' || true)"

  printf '%-16s %-10s %-10s %-10s\n' HOST PLATFORM SERVICES SECRETS
  for h in $nixos_hosts; do
    local s c
    s="$(nh_host_eval "$h" nixos nixhold.services | jq '[.[] | select(.enable // false)] | length')"
    c="$(nh_host_eval "$h" nixos nixhold.secrets | jq 'length')"
    printf '%-16s %-10s %-10s %-10s\n' "$h" nixos "$s" "$c"
  done
  for h in $darwin_hosts; do
    local s c
    s="$(nh_host_eval "$h" darwin nixhold.services | jq '[.[] | select(.enable // false)] | length')"
    c="$(nh_host_eval "$h" darwin nixhold.secrets | jq 'length')"
    printf '%-16s %-10s %-10s %-10s\n' "$h" darwin "$s" "$c"
  done
}
