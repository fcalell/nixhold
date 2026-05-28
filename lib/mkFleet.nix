# mkFleet — single forker-facing entrypoint.
#
# Signature locked in ROADMAP "Framework wiring":
#   { inputs, identity, networks, hosts, layout }
#
# Reads no files from disk (principle 14). Dispatches per arch
# family — separate builders for NixOS and Darwin, no
# `isDarwin` branching inside one builder. Per-host module list:
#
#   1. inputs.nixhold.<platform>Modules.nixhold  -- baseline bundle
#   2. host.profile                              -- the profile attached in `hosts.<n>`
#   3. baseline name host                        -- hostname + nixhold.{identity,layout,fleet}
#   4. host.modules                              -- operator's per-host modules
{
  inputs,
  identity,
  networks,
  hosts,
  layout,
}:
let
  inherit (inputs.nixhold.inputs) nixpkgs nix-darwin;
  lib = nixpkgs.lib;

  fleetView = {
    inherit hosts;
    network = networks;
  };

  isLinux = arch: lib.hasSuffix "-linux" arch;
  isDarwin = arch: lib.hasSuffix "-darwin" arch;

  linuxHosts = lib.filterAttrs (_: h: isLinux h.arch) hosts;
  darwinHosts = lib.filterAttrs (_: h: isDarwin h.arch) hosts;

  baseline = name: host: [
    (
      { lib, ... }:
      {
        networking.hostName = lib.mkDefault name;
        nixpkgs.hostPlatform = lib.mkDefault host.arch;
        nixhold = {
          inherit identity layout;
          fleet = fleetView;
        };
      }
    )
  ];

  mkNixosHost =
    name: host:
    nixpkgs.lib.nixosSystem {
      system = host.arch;
      specialArgs = {
        inherit inputs identity;
        fleet = fleetView;
        hostname = name;
      };
      modules = [
        inputs.nixhold.nixosModules.nixhold
      ]
      ++ [ host.profile ]
      ++ baseline name host
      ++ host.modules;
    };

  mkDarwinHost =
    name: host:
    nix-darwin.lib.darwinSystem {
      system = host.arch;
      specialArgs = {
        inherit inputs identity;
        fleet = fleetView;
        hostname = name;
      };
      modules = [
        inputs.nixhold.darwinModules.nixhold
      ]
      ++ [ host.profile ]
      ++ baseline name host
      ++ host.modules;
    };
in
{
  nixosConfigurations = lib.mapAttrs mkNixosHost linuxHosts;
  darwinConfigurations = lib.mapAttrs mkDarwinHost darwinHosts;

  # Re-export the framework's per-system CLI surface so a forker's
  # flake can `nix run .#nixhold -- <verb>` and `nix fmt` from the
  # fleet repo, not just against `github:fcalell/nixhold`.
  inherit (inputs.nixhold) packages apps formatter;
}
