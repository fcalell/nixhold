{
  description = "nixhold — opinionated Nix-native personal-infrastructure framework";

  # Inputs follow nixpkgs uniformly so the framework's lock file
  # is consistent. Forkers who need a newer nixpkgs declare it in
  # their own flake and rebind `inputs.nixhold.inputs.nixpkgs.follows`.
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    nix-darwin = {
      url = "github:nix-darwin/nix-darwin/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager = {
      url = "github:nix-community/home-manager/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
      inputs.darwin.follows = "nix-darwin";
    };

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixos-anywhere = {
      url = "github:nix-community/nixos-anywhere";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.disko.follows = "disko";
    };

    nixos-hardware.url = "github:NixOS/nixos-hardware/master";
  };

  outputs =
    { self, nixpkgs, ... }@inputs:
    let
      forAllSystems = nixpkgs.lib.genAttrs [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      # Baseline module bundles. mkFleet auto-imports these into
      # every host's module list. Forkers can reach them as
      # `inputs.nixhold.nixosModules.nixhold` etc. but the
      # recommended path is `mkFleet`.
      nixosBaseline = import ./modules/baseline-nixos.nix;
      darwinBaseline = import ./modules/baseline-darwin.nix;
      homeBaseline = import ./modules/baseline-home.nix;
    in
    {
      lib.mkFleet = import ./lib/mkFleet.nix;

      nixosModules.nixhold = nixosBaseline;
      darwinModules.nixhold = darwinBaseline;
      homeManagerModules.nixhold = homeBaseline;

      # Per-service / per-infra modules surfaced individually so
      # profiles (and forker-authored profiles) can compose them
      # without pulling in the whole catalogue.
      modules = {
        services = {
          openssh = ./modules/services/openssh/nixos.nix;
          tailscale = ./modules/services/tailscale/nixos.nix;
        };
        infra = {
          caddy = ./modules/infra/caddy.nix;
          firewall = ./modules/infra/firewall.nix;
        };
      };

      # Framework-shipped profiles — populated below.
      profiles = {
        server = ./profiles/server.nix;
        workstationDarwin = ./profiles/workstationDarwin.nix;
        desktopLinux = ./profiles/desktopLinux.nix;
      };

      # `nix flake init -t github:fcalell/nixhold` scaffolds a
      # fresh fleet from `./template`.
      templates.default = {
        path = ./template;
        description = "A new nixhold-managed fleet.";
      };

      # The `nixhold` CLI, packaged as a single writeShellApplication.
      # Forkers reach it as `nix run github:fcalell/nixhold#nixhold --`
      # pre-install, and via `programs.nixhold.enable` post-install.
      packages = forAllSystems (system: {
        nixhold = import ./cli {
          pkgs = nixpkgs.legacyPackages.${system};
        };
      });

      apps = forAllSystems (system: {
        nixhold = {
          type = "app";
          program = "${self.packages.${system}.nixhold}/bin/nixhold";
        };
        default = self.apps.${system}.nixhold;
      });

      # CI check: build the synthetic fleet so any regression in
      # mkFleet, baseline modules, or profiles fails here first.
      checks = forAllSystems (
        system:
        let
          fixture = import ./checks/fixture { inherit inputs self; };
        in
        nixpkgs.lib.optionalAttrs (system == "x86_64-linux") {
          fixture-server = fixture.nixosConfigurations.fixture-server.config.system.build.toplevel;

          # The fleet's own installer image. Evaluating it covers the
          # whole ISO module — including the "THIN by contract"
          # assertion that no baked ciphertext is a subpath of the
          # fleet checkout, which is why the fixture hands mkFleet a
          # store path for `self` (see checks/fixture/self.nix): a
          # bare `./.` would make the fleet source indistinguishable
          # from the framework's own.
          fixture-iso = fixture.packages.x86_64-linux.installerIso;
        }
        // nixpkgs.lib.optionalAttrs (system == "aarch64-darwin") {
          fixture-mac = fixture.darwinConfigurations.fixture-mac.system;
        }
      );

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt);
    };
}
