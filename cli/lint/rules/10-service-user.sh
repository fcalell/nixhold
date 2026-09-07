# Rule: no systemd unit runs as the operator account.
#
# `serviceConfig.User = <the operator>` hands a long-running,
# network-facing process the identity the whole fleet is administered
# with: the operator is in `wheel`, is a nix trusted-user, owns the
# fleet checkout, and holds ~/.ssh/identity — the key that authenticates
# to every peer and every forge. A bug in that service is then not a
# service compromise but an operator compromise, and nothing in the
# system distinguishes what the daemon did from what the person did.
#
# The fix is a user of the unit's own: `DynamicUser = true` where the
# service keeps no state, or a declared `users.users.<svc>` with the
# state directory owned by it. The framework's own service modules take
# the second route (see the `owner` of a `nixhold.secrets.<name>` with
# a `unit`).
#
# A WARNING in dev AND under --strict: a fleet that predates the rule
# has hosts it applies to, and a unit that genuinely wants the
# operator's home (a personal agent, a syncthing over $HOME) is a
# legitimate, if rare, answer. This rule is here to make the choice
# deliberate, not to block a deploy.

root="$(nh_fleet_root)" || exit 2
nixos_hosts="$(nix eval --json --no-warn-dirty "$root#nixosConfigurations" --apply 'builtins.attrNames' 2>/dev/null | jq -r '.[]?' || true)"

worst=0
problems=0
for h in $nixos_hosts; do
  # One eval per host, and only `serviceConfig.User` is forced out of
  # each unit — `nh_host_eval "$h" nixos systemd.services` would
  # serialise every unit's full merged config to JSON.
  # shellcheck disable=SC2016 # a Nix expression, not a shell one
  json="$(nix eval --json --no-warn-dirty "$root#nixosConfigurations.$h.config" --apply '
    c:
    let
      op = c.nixhold.identity.username;
      svcs = c.systemd.services;
      # home-manager activation is the one unit that MUST run as the
      # operator: it writes that home directory. A oneshot that runs
      # at switch and exits is not a daemon holding the account open,
      # so it is exempt rather than a finding nobody can act on.
      exempt = [ "home-manager-${op}" ];
      runsAsOperator =
        n: !(builtins.elem n exempt) && ((svcs.${n}.serviceConfig or { }).User or null) == op;
    in
    {
      user = op;
      units = builtins.filter runsAsOperator (builtins.attrNames svcs);
    }' 2>/dev/null)" || {
    echo "ERROR: could not evaluate systemd.services for $h — service-user check skipped"
    [ "$worst" -lt 2 ] && worst=2
    continue
  }

  user="$(echo "$json" | jq -r '.user')"
  while IFS= read -r unit; do
    [ -n "$unit" ] || continue
    problems=$((problems + 1))
    echo "WARNING: $h: unit $unit runs as the operator ($user); give it a dedicated user"
  done < <(echo "$json" | jq -r '.units[]?')
done

if [ "$problems" -eq 0 ] && [ "$worst" -eq 0 ]; then
  echo "OK: no unit runs as the operator account"
fi
exit "$worst"
