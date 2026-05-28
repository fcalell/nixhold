# Rule 13 (v1 single-gateway invariant):
# `derived.publicHosts` length must be ≤ 1.

root="$(nh_fleet_root)" || exit 2
nixos_hosts="$(nix eval --json --no-warn-dirty "$root#nixosConfigurations" --apply 'builtins.attrNames' 2>/dev/null | jq -r '.[]?' || true)"
first_host="$(echo "$nixos_hosts" | head -1)"
if [ -z "$first_host" ]; then
  echo "OK: no nixos hosts to check"
  exit 0
fi

count="$(nh_host_eval "$first_host" nixos nixhold.fleet.derived.publicHosts | jq 'length')"
if [ "$count" -gt 1 ]; then
  echo "VIOLATION: $count hosts have publicIp set; v1 allows ≤ 1"
  exit 3
fi
echo "OK: single-gateway invariant holds ($count public host(s))"
exit 0
