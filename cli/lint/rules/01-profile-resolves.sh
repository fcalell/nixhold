# Rule 01: every host's profile resolves to a value.
# A broken `host.profile` reference (e.g. a typo) makes the whole
# host config fail to evaluate, so the smoke test forces a host eval
# and reads a serializable leaf. `derived.self` itself can't be the
# probe — it carries the host's `profile` (a module value), which is
# not JSON-serializable — so read `derived.self.arch` (a string).

root="$(nh_fleet_root)" || exit 2

nixos_hosts="$(nix eval --json --no-warn-dirty "$root#nixosConfigurations" --apply 'builtins.attrNames' 2>/dev/null | jq -r '.[]?' || true)"
darwin_hosts="$(nix eval --json --no-warn-dirty "$root#darwinConfigurations" --apply 'builtins.attrNames' 2>/dev/null | jq -r '.[]?' || true)"

worst=0
for h in $nixos_hosts; do
  if nh_host_eval "$h" nixos nixhold.fleet.derived.self.arch >/dev/null 2>&1; then
    echo "OK: profile resolves for $h"
  else
    echo "VIOLATION: profile fails to resolve for $h"
    worst=3
  fi
done
for h in $darwin_hosts; do
  if nh_host_eval "$h" darwin nixhold.fleet.derived.self.arch >/dev/null 2>&1; then
    echo "OK: profile resolves for $h"
  else
    echo "VIOLATION: profile fails to resolve for $h"
    worst=3
  fi
done

exit "$worst"
