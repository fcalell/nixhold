# mkFleet — single forker-facing entrypoint.
#
# Signature locked in ROADMAP "Fleet contract — mkFleet":
#   { inputs, identity, networks, hosts, layout ? { } }
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
  layout ? { },
}:
let
  inherit (inputs.nixhold.inputs) nixpkgs nix-darwin;
  lib = nixpkgs.lib;

  # Every layout field is a computed subpath of the forker's own
  # flake root — values off `inputs.self`, never directory walking
  # (principle 14). `repoUrl` is the one field nothing can derive.
  # Merge is per-field: an operator who overrides one path keeps
  # the defaults for the rest.
  layoutDefaults = {
    secrets = inputs.self + "/secrets";
    hostsFile = inputs.self + "/hosts.nix";
    modulesDir = inputs.self + "/modules";
    profilesDir = inputs.self + "/profiles";
    keysDir = inputs.self + "/keys";
    ageRecipient = inputs.self + "/keys/operator.pub";
    ageIdentityWrapped = inputs.self + "/keys/operator.age";
    repoUrl = null;
  };
  resolvedLayout = layoutDefaults // layout;

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
          inherit identity;
          layout = resolvedLayout;
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

  nixosConfigurations = lib.mapAttrs mkNixosHost linuxHosts;

  # The ISO authorizes the operator's login keys on root. Read them
  # off a built host instead of re-deriving: `fleet.derived` is the
  # single place per-host `loginPubkey` defaults resolve, and every
  # host in a fleet sees the same union.
  operatorAuthorizedKeys =
    (lib.head (lib.attrValues nixosConfigurations)).config.nixhold.fleet.derived.operatorAuthorizedKeys;

  # One image per Linux arch the fleet actually has a host on — the
  # ISO exists to install *this* fleet's hosts.
  isoArches = lib.unique (lib.mapAttrsToList (_: h: h.arch) linuxHosts);

  mkInstallerIso =
    arch:
    (nixpkgs.lib.nixosSystem {
      system = arch;
      modules = [
        "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"
        (import ./installer-iso.nix {
          inherit operatorAuthorizedKeys;
          repoUrl = resolvedLayout.repoUrl;
          ageIdentityWrapped = resolvedLayout.ageIdentityWrapped;
          repoDeployKey = resolvedLayout.keysDir + "/repo.key.age";
          diskoPackage = inputs.nixhold.inputs.disko.packages.${arch}.disko;
        })
      ];
    }).config.system.build.isoImage;

  # The attr is always present so discovery stays predictable: a
  # fleet that hasn't named its repo gets the reason on force,
  # not a missing attribute.
  isoPackages = lib.genAttrs isoArches (arch: {
    installerIso =
      if resolvedLayout.repoUrl == null then
        throw "nixhold: set layout.repoUrl (\"owner/repo\") to build the installer ISO — the image has to know which fleet repo to clone"
      else
        mkInstallerIso arch;
  });

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
  inherit nixosConfigurations;
  darwinConfigurations = lib.mapAttrs mkDarwinHost darwinHosts;

  # Re-export the framework's per-system CLI surface so a forker's
  # flake can `nix run .#nixhold -- <verb>` and `nix fmt` from the
  # fleet repo, not just against `github:fcalell/nixhold`. The
  # fleet's own `installerIso` merges into that surface — it is
  # fleet-specific (repo URL, operator keys), so it can't come from
  # the framework's re-exported packages, and must not clobber them.
  packages = lib.recursiveUpdate inputs.nixhold.packages isoPackages;
  inherit (inputs.nixhold) apps formatter;
}
