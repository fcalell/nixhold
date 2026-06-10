# Rule 13 (v1 single-gateway invariant):
# `derived.publicHosts` length must be ≤ 1.

root="$(nh_fleet_root)" || exit 2
# `derived.publicHosts` is fleet-global, so any one host's view works —
# including a darwin host on a darwin-only fleet.
platform=nixos
nixos_hosts="$(nix eval --json --no-warn-dirty "$root#nixosConfigurations" --apply 'builtins.attrNames' 2>/dev/null | jq -r '.[]?' || true)"
first_host="$(echo "$nixos_hosts" | head -1)"
if [ -z "$first_host" ]; then
  platform=darwin
  darwin_hosts="$(nix eval --json --no-warn-dirty "$root#darwinConfigurations" --apply 'builtins.attrNames' 2>/dev/null | jq -r '.[]?' || true)"
  first_host="$(echo "$darwin_hosts" | head -1)"
fi
if [ -z "$first_host" ]; then
  echo "OK: no hosts to check"
  exit 0
fi

count="$(nh_host_eval "$first_host" "$platform" nixhold.fleet.derived.publicHosts 2>/dev/null | jq 'length')" || count=""
if [ -z "$count" ]; then
  echo "ERROR: could not evaluate derived.publicHosts via $first_host"
  exit 2
fi
if [ "$count" -gt 1 ]; then
  echo "VIOLATION: $count hosts have publicIp set; v1 allows ≤ 1"
  exit 3
fi
echo "OK: single-gateway invariant holds ($count public host(s))"
exit 0
