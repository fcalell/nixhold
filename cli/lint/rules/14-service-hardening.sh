# Rule: every unit the framework or the fleet defines takes the
# hardening set.
#
# `inputs.nixhold.lib.hardening` is one serviceConfig block a unit
# merges (ARCHITECTURE "One hardening set"); a unit written without
# it runs open, and the third copy of the block was how the set came
# to exist. Which units are ours is read from where they are
# defined: `options.systemd.services.definitionsWithLocations` names
# the file of every definition, and a unit is ours when a file under
# nixhold's or the fleet's own source defines it and no file under
# nixpkgs does. nixpkgs-owned units keep nixpkgs' hardening, and so a
# unit nixhold only decorates (an EnvironmentFile, a RuntimeDirectory
# on a nixpkgs unit) is nixpkgs'; home-manager's and agenix's units
# are theirs. A unit that runs no command of its own is skipped.
#
# `NoNewPrivileges = true` is the mark: every field of the set is a
# legitimate exception somewhere, that one never is.
#
# A WARNING in dev, an ERROR under --strict. Exemptions are a closed
# list here, never a per-fleet knob.

root="$(nh_fleet_root)" || exit 2
strict="${NIXHOLD_LINT_STRICT:-0}"
nixos_hosts="$(nix eval --json --no-warn-dirty "$root#nixosConfigurations" --apply 'builtins.attrNames' 2>/dev/null | jq -r '.[]?' || true)"

worst=0
problems=0
for h in $nixos_hosts; do
  # shellcheck disable=SC2016 # a Nix expression, not a shell one
  json="$(nix eval --json --no-warn-dirty "$root#nixosConfigurations.$h" --apply '
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
      exempt = [ ];
      ours = lib.subtractLists (definedUnder [ host.pkgs.path ]) (
        definedUnder [ inputs.nixhold.outPath inputs.self.outPath ]
      );
      runs = n: (svcs.${n}.serviceConfig or { }) ? ExecStart;
      open = n: ((svcs.${n}.serviceConfig or { }).NoNewPrivileges or false) != true;
    in
    builtins.filter (n: !(builtins.elem n exempt) && runs n && open n) ours' 2>/dev/null)" || {
    echo "ERROR: could not evaluate systemd.services for $h — service-hardening check skipped"
    [ "$worst" -lt 2 ] && worst=2
    continue
  }

  while IFS= read -r unit; do
    [ -n "$unit" ] || continue
    problems=$((problems + 1))
    if [ "$strict" = "1" ]; then
      echo "ERROR: $h: unit $unit runs a command without the hardening set (inputs.nixhold.lib.hardening)"
      [ "$worst" -lt 2 ] && worst=2
    else
      echo "WARNING: $h: unit $unit runs a command without the hardening set (inputs.nixhold.lib.hardening)"
      [ "$worst" -lt 1 ] && worst=1
    fi
  done < <(echo "$json" | jq -r '.[]?')
done

if [ "$problems" -eq 0 ] && [ "$worst" -eq 0 ]; then
  echo "OK: every unit the framework or the fleet defines takes the hardening set"
fi
exit "$worst"
