# mkFleet — single forker-facing entrypoint.
#
# Signature locked in ARCHITECTURE "Fleet contract — mkFleet":
#   { inputs, identity, networks, hosts, layout ? { } }
#
# Reads no files from disk (principle 14). Dispatches per arch
# family — separate builders for NixOS, Darwin and Android, no
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
    hostsDir = inputs.self + "/hosts";
    modulesDir = inputs.self + "/modules";
    profilesDir = inputs.self + "/profiles";
    keysDir = inputs.self + "/keys";
    ageRecipient = inputs.self + "/keys/operator.pub";
    # The one default that is conditional: a fleet whose only route
    # to its own secrets is a hardware token commits no wrapped
    # identity, and pointing at a file that is not there would turn
    # "no passphrase route" into a missing-path eval error. Same
    # named principle-14 exception as `nixhold.layout`'s own default
    # — the path is computed off `self`, `pathExists` only says
    # whether that computed path is populated.
    ageIdentityWrapped =
      let
        p = inputs.self + "/keys/operator.age";
      in
      if builtins.pathExists p then p else null;
    repoUrl = null;
  };
  resolvedLayout = layoutDefaults // layout;

  fleetView = {
    inherit hosts;
    network = networks;
  };

  isLinux = arch: lib.hasSuffix "-linux" arch;
  isDarwin = arch: lib.hasSuffix "-darwin" arch;
  isAndroid = arch: lib.hasSuffix "-android" arch;

  linuxHosts = lib.filterAttrs (_: h: isLinux h.arch) hosts;
  darwinHosts = lib.filterAttrs (_: h: isDarwin h.arch) hosts;
  androidHosts = lib.filterAttrs (_: h: isAndroid h.arch) hosts;

  baseline = name: host: [
    (
      { lib, ... }:
      {
        # The OS hostname only *defaults* to the fleet key — a host
        # may be renamed (MDM, corporate naming) without changing
        # which fleet entry it is. `nixhold.fleet.selfName` carries
        # that identity, so secrets, recipients and `derived.self`
        # stay put when the OS name moves.
        networking.hostName = lib.mkDefault name;
        nixhold = {
          inherit identity;
          layout = resolvedLayout;
          fleet = fleetView // {
            selfName = name;
          };
        };
      }
    )
  ];

  # The system the host builds for: a nixpkgs concern, so it sits
  # beside the two builders that have one and not in the baseline an
  # Android host shares.
  hostPlatform = host: { lib, ... }: { nixpkgs.hostPlatform = lib.mkDefault host.arch; };

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
        (hostPlatform host)
      ]
      ++ [ host.profile ]
      ++ baseline name host
      ++ host.modules;
    };

  nixosConfigurations = lib.mapAttrs mkNixosHost linuxHosts;

  # The ISO authorizes the operator's login keys on root. It needs
  # exactly one derived value, so evaluate exactly the modules that
  # derive it — the same `nixhold.fleet` namespace every host carries,
  # with no platform, no profile and no operator modules attached.
  # Reading it off a host instead would couple the image to that
  # host's whole eval: an unrelated error anywhere in the
  # alphabetically-first Linux host would surface as an ISO failure.
  fleetNamespace = lib.evalModules {
    modules = [
      ../modules/layout
      ../modules/fleet
      ../modules/fleet/derived.nix
      {
        nixhold.layout = resolvedLayout;
        nixhold.fleet = fleetView;
      }
    ];
  };

  operatorAuthorizedKeys =
    let
      keys = fleetNamespace.config.nixhold.fleet.derived.operatorAuthorizedKeys;
    in
    if keys == [ ] then
      throw "nixhold installer ISO: `keys/login.pub` is missing or empty — the image would boot with root unreachable. Commit one login pubkey per line there (the public halves of your hardware-token login keys), or run `nixhold secret edit identity`, which writes the fleet key's own pubkey to that file when it is absent"
    else
      keys;

  # One image per Linux arch the fleet actually has a host on — the
  # ISO exists to install *this* fleet's hosts.
  isoArches = lib.unique (lib.mapAttrsToList (_: h: h.arch) linuxHosts);

  # The ISO's clone credential: the fleet's own `identity` ssh key,
  # already registered on the forge for authentication. A deploy key
  # of its own would be a second credential to mint, register and
  # revoke for a journey the fleet key already makes.
  cloneKey = resolvedLayout.secrets + "/identity.age";

  # Every operator route committed in `ageRecipient` — one recipient
  # per line, see lib/pubkey-lines.nix. The ISO needs the list to
  # assert that at least ONE of them is a route it can actually offer
  # a booted operator: a token line, or the wrapped identity it bakes.
  ageRecipients =
    if builtins.pathExists resolvedLayout.ageRecipient then
      import ./pubkey-lines.nix resolvedLayout.ageRecipient
    else
      [ ];

  mkInstallerIso =
    arch:
    (nixpkgs.lib.nixosSystem {
      system = arch;
      modules = [
        "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"
        (import ./installer-iso.nix {
          inherit operatorAuthorizedKeys cloneKey ageRecipients;
          repoUrl = resolvedLayout.repoUrl;
          ageIdentityWrapped = resolvedLayout.ageIdentityWrapped;
          diskoPackage = inputs.nixhold.inputs.disko.packages.${arch}.disko;
        })
      ];
    }).config.system.build.isoImage;

  # The attr exists only for a fleet the image can actually be built
  # for: a repo to clone, the `identity` ciphertext on disk to clone it
  # with, and a route the booted operator can unlock that with — a
  # FIDO2 token recipient (the plugin is on the image, the private half
  # is on the operator's keyring) or a committed passphrase-wrapped
  # identity. Emitting it unconditionally would make `nix flake check`
  # / `nix flake show` fail on every fleet that has not reached
  # `nixhold iso` yet, since both force the attribute. `nixhold iso` is
  # the verb that explains what is missing, and lint warns about the
  # absent clone key — neither needs the package to exist to do that.
  # The ISO module re-checks the route as an assertion, for the same
  # reason its THIN check is an assertion: to hold for a module used
  # outside mkFleet.
  isoBakeable =
    resolvedLayout.repoUrl != null
    && (
      resolvedLayout.ageIdentityWrapped != null || lib.any (lib.hasPrefix "age1fido2-hmac1") ageRecipients
    )
    && builtins.pathExists cloneKey;

  isoPackages = lib.optionalAttrs isoBakeable (
    lib.genAttrs isoArches (arch: {
      installerIso = mkInstallerIso arch;
    })
  );

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
        (hostPlatform host)
      ]
      ++ [ host.profile ]
      ++ baseline name host
      ++ host.modules;
    };

  # An Android host builds nothing for itself: its product is a plan
  # (APKs and one JSON) the seat running `nixhold deploy` builds and
  # applies over adb. So the eval is keyed by that seat's system —
  # `pkgs` is the seat's, and there is one eval per system the CLI is
  # packaged for — where the other two families are keyed by nothing.
  # Same module order as theirs; `lib.evalModules`, since neither
  # nixpkgs nor nix-darwin has a module tree for the device.
  seatSystems = builtins.attrNames inputs.nixhold.packages;

  mkAndroidHost =
    system: name: host:
    lib.evalModules {
      specialArgs = {
        inherit inputs identity;
        fleet = fleetView;
        hostname = name;
        pkgs = nixpkgs.legacyPackages.${system};
      };
      modules = [
        inputs.nixhold.androidModules.nixhold
      ]
      ++ [ host.profile ]
      ++ baseline name host
      ++ host.modules;
    };
in
{
  inherit nixosConfigurations;
  darwinConfigurations = lib.mapAttrs mkDarwinHost darwinHosts;
  androidConfigurations = lib.genAttrs seatSystems (
    system: lib.mapAttrs (mkAndroidHost system) androidHosts
  );

  # Re-export the framework's per-system CLI surface so a forker's
  # flake can `nix run .#nixhold -- <verb>` and `nix fmt` from the
  # fleet repo, not just against `github:fcalell/nixhold`. The
  # fleet's own `installerIso` merges into that surface — it is
  # fleet-specific (repo URL, operator keys), so it can't come from
  # the framework's re-exported packages, and must not clobber them.
  packages = lib.recursiveUpdate inputs.nixhold.packages isoPackages;
  inherit (inputs.nixhold) apps formatter;
}
