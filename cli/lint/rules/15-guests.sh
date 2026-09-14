# Rule: a guest is a well-formed host of its machine ("Guests").
#
# The roster names guests on the machine that runs them, so the shape
# is checked from the machine entries: a guest is a roster host named
# by at most one machine; its machine is NixOS and of the guest's
# arch (one kernel runs both); the guest carries no `disk` (its
# hardware is the machine's), no `guests` (nesting is not a shape),
# no `publicIp` or `publicFqdn` (the gateway is the host with the
# public address, which a guest's veth is not); every granted device
# is a path under /dev. Those are errors: a fleet that evaluates with
# them deploys something other than what the roster reads as.
#
# Then the grant against use: every `DeviceAllow` node in a unit the
# framework or the fleet defines on the guest (the same "ours" as rule
# 14) is within the machine's grant — the node itself, `/dev/net/tun`
# (every guest has it), a `char-drm` class with a render node granted,
# a `char-alsa`/`char-sound` class or a `/dev/snd/*` node with a card
# granted. A unit wanting a device its machine never gave is a warning
# in dev and an error under --strict.

root="$(nh_fleet_root)" || exit 2
strict="${NIXHOLD_LINT_STRICT:-0}"
view="$(nh_fleet_view)" || exit 2

worst=0
problems=0
fail() {
  problems=$((problems + 1))
  echo "VIOLATION: $1"
  worst=3
}
report() {
  problems=$((problems + 1))
  if [ "$strict" = "1" ]; then
    echo "VIOLATION: $1"
    worst=3
  else
    echo "WARNING: $1"
    [ "$worst" -lt 1 ] && worst=1
  fi
}

# --- the roster shape, one line per (machine, guest) pair ---
while IFS=$'\t' read -r machine mplatform march guest; do
  [ -n "$machine" ] || continue
  if [ "$mplatform" != "nixos" ]; then
    fail "$machine names $guest as a guest but is $mplatform — only a NixOS machine runs containers"
    continue
  fi
  gjson="$(printf '%s' "$view" | jq -c --arg g "$guest" '.hosts[$g] // empty')"
  if [ -z "$gjson" ]; then
    fail "$machine names $guest as a guest, but there is no host '$guest' in the roster"
    continue
  fi
  garch="$(printf '%s' "$gjson" | jq -r '.arch')"
  [ "$garch" = "$march" ] || fail "$guest is $garch but its machine $machine is $march — a guest shares its machine's kernel"
  [ "$(printf '%s' "$gjson" | jq -r '.disk // empty')" = "" ] || fail "$guest carries a disk but is a guest of $machine — a guest owns no disk (drop 'disk' from its entry)"
  [ "$(printf '%s' "$gjson" | jq -r '.guests | length')" = "0" ] || fail "$guest names guests of its own but is a guest of $machine — nesting is not a shape"
  [ "$(printf '%s' "$gjson" | jq -r '.publicIp // empty')" = "" ] || fail "$guest has a publicIp but is a guest of $machine — the gateway is a machine"
  [ "$(printf '%s' "$gjson" | jq -r '.publicFqdn // empty')" = "" ] || fail "$guest has a publicFqdn but is a guest of $machine — the gateway is a machine"
  while IFS= read -r dev; do
    [ -n "$dev" ] || continue
    case "$dev" in
      /dev/dri/* | /dev/snd/by-id/*) ;;
      /dev/*) report "$machine grants $guest '$dev', which is neither a render node (/dev/dri/*) nor a sound card (/dev/snd/by-id/*) — nothing renders it" ;;
      *) fail "$machine grants $guest '$dev', which is not a path under /dev" ;;
    esac
  done < <(printf '%s' "$view" | jq -r --arg m "$machine" --arg g "$guest" '.hosts[$m].guests[$g].devices[]?')
done < <(printf '%s' "$view" | jq -r '
  .hosts | to_entries[]
  | .key as $m | .value as $h
  | ($h.guests // {} | keys[]) as $g
  | [ $m, $h.platform, $h.arch, $g ] | @tsv')

# A guest named by two machines.
while IFS= read -r line; do
  [ -n "$line" ] || continue
  fail "$line"
done < <(printf '%s' "$view" | jq -r '
  [ .hosts | to_entries[] | .key as $m | (.value.guests // {} | keys[]) | { guest: ., machine: $m } ]
  | group_by(.guest)[] | select(length > 1)
  | "\(.[0].guest) is named as a guest by \(map(.machine) | join(" and ")) — a guest has one machine"')

# --- the grant against the guest's own units ---
while IFS=$'\t' read -r guest machine; do
  [ -n "$guest" ] || continue
  grant="$(printf '%s' "$view" | jq -c --arg m "$machine" --arg g "$guest" '.hosts[$m].guests[$g].devices // []')"
  # shellcheck disable=SC2016 # a Nix expression, not a shell one
  json="$(nix eval --json --no-warn-dirty "$root#nixosConfigurations.$guest" --apply '
    host:
    let
      lib = host.pkgs.lib;
      svcs = host.config.systemd.services;
      inputs = host._module.specialArgs.inputs;
      under = roots: d: lib.any (r: lib.hasPrefix (toString r) d.file) roots;
      definedUnder = roots: lib.unique (
        lib.concatMap (d: lib.attrNames d.value) (
          lib.filter (under roots) host.options.systemd.services.definitionsWithLocations
        )
      );
      ours = lib.subtractLists (definedUnder [ host.pkgs.path ]) (
        definedUnder [ inputs.nixhold.outPath inputs.self.outPath ]
      );
      allow = n: lib.toList ((svcs.${n}.serviceConfig or { }).DeviceAllow or [ ]);
      node = s: lib.head (lib.splitString " " s);
    in
    lib.concatMap (n: map (s: { unit = n; node = node s; }) (allow n)) ours' 2>/dev/null)" || {
    echo "ERROR: could not evaluate systemd.services for $guest — guest device check skipped"
    [ "$worst" -lt 2 ] && worst=2
    continue
  }
  hasRender="$(printf '%s' "$grant" | jq 'any(.[]; startswith("/dev/dri/"))')"
  hasCard="$(printf '%s' "$grant" | jq 'any(.[]; startswith("/dev/snd/by-id/"))')"
  while IFS=$'\t' read -r unit node; do
    [ -n "$unit" ] || continue
    ok=0
    case "$node" in
      /dev/net/tun) ok=1 ;;
      char-drm) [ "$hasRender" = "true" ] && ok=1 ;;
      char-alsa | char-sound | /dev/snd/*) [ "$hasCard" = "true" ] && ok=1 ;;
      *) [ "$(printf '%s' "$grant" | jq --arg n "$node" 'index($n) != null')" = "true" ] && ok=1 ;;
    esac
    [ "$ok" -eq 1 ] || report "$guest: unit $unit allows '$node', which $machine's grant does not hold (hosts.$machine.guests.$guest.devices)"
  done < <(printf '%s' "$json" | jq -r '.[] | [ .unit, .node ] | @tsv')
done < <(printf '%s' "$view" | jq -r '.machineOf | to_entries[] | [ .key, .value ] | @tsv')

if [ "$problems" -eq 0 ] && [ "$worst" -eq 0 ]; then
  echo "OK: every guest is a well-formed host of one NixOS machine, within its grant"
fi
exit "$worst"
