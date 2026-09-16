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
      androidBaseline = import ./modules/baseline-android.nix;
    in
    {
      lib.mkFleet = import ./lib/mkFleet.nix;
      lib.hardening = import ./lib/hardening.nix;

      # No `homeManagerModules`: home-manager is wired by the platform
      # baselines (modules/home/), which need `nixhold.identity` and
      # `nixhold.secrets` from the system config. Standalone
      # home-manager is not a shape this framework serves.
      nixosModules.nixhold = nixosBaseline;
      darwinModules.nixhold = darwinBaseline;
      androidModules.nixhold = androidBaseline;

      # Per-service / per-infra modules surfaced individually so
      # profiles (and forker-authored profiles) can compose them
      # without pulling in the whole catalogue.
      modules = {
        # Services are keyed by platform: a service can carry an
        # implementation on more than one, and the import path is
        # what names the platform a profile is asking for. Infra is
        # NixOS-only, so it stays flat.
        services = {
          nixos = {
            navidrome = ./modules/services/navidrome/nixos.nix;
            openssh = ./modules/services/openssh/nixos.nix;
            syncthing = ./modules/services/syncthing/nixos.nix;
            taskchampion = ./modules/services/taskchampion/nixos.nix;
            tailscale = ./modules/services/tailscale/nixos.nix;
            vaultwarden = ./modules/services/vaultwarden/nixos.nix;
          };
          darwin = {
            syncthing = ./modules/services/syncthing/darwin.nix;
            tailscale = ./modules/services/tailscale/darwin.nix;
          };
        };
        infra = {
          caddy = ./modules/infra/caddy.nix;
          firewall = ./modules/infra/firewall.nix;
          backups = ./modules/infra/backups.nix;
          # The adb key's declaration, for a NixOS host that drives an
          # Android device itself (every Android host has it already).
          adbKey = ./modules/android/adb-key.nix;
        };
      };

      # Framework-shipped profiles — populated below.
      profiles = {
        server = ./profiles/server.nix;
        workstationDarwin = ./profiles/workstationDarwin.nix;
        desktopLinux = ./profiles/desktopLinux.nix;
        # Android hosts, by use rather than by device: a screen the
        # fleet owns, and a person's phone or tablet.
        kiosk = ./profiles/kiosk.nix;
        mobile = ./profiles/mobile.nix;
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
        {
          # The CLI itself, and shellcheck over every verb and library
          # it sources. writeShellApplication only checks the two-line
          # wrapper in cli/default.nix; the sourced files are copied
          # into the store unread, so this is the gate that reads them.
          nixhold = self.packages.${system}.nixhold;
          cli-shellcheck =
            let
              pkgs = nixpkgs.legacyPackages.${system};
            in
            pkgs.runCommand "nixhold-cli-shellcheck" { nativeBuildInputs = [ pkgs.shellcheck ]; } ''
              cd ${./cli}
              # SC1090: the dispatcher and the lint runner source by
              # computed name; every file they can reach is checked here
              # directly. The locale is for shellcheck's own output —
              # the sources carry UTF-8 in their messages.
              export LC_ALL=C.UTF-8
              shellcheck -x -s bash -e SC1090 ./*.sh lib/*.sh lint/rules/*.sh
              touch $out
            '';

          # What shellcheck cannot see: the dispatcher sources ONE verb
          # plus every lib/, so a verb calling a function another verb
          # defines finds nothing at runtime — and `|| true` swallows
          # the "command not found" that would say so.
          cli-symbols =
            let
              pkgs = nixpkgs.legacyPackages.${system};
            in
            pkgs.runCommand "nixhold-cli-symbols" { } ''
              cd ${./cli}
              # "No match" is an answer here, not a failure; stdenv
              # builds under pipefail, where grep's 1 would end this one.
              match() { grep "$@" || true; }
              defs() { match -hoE '^nh_[a-z0-9_]+\(\)' "$@" | tr -d '()'; }
              rc=0
              for f in ./*.sh; do
                # A verb that sources a sibling verb gets its functions too.
                siblings=$(match -oE '\$NIXHOLD_LIB_ROOT/[a-z-]+\.sh' "$f" | sed 's|.*/||' | sort -u)
                known=$(defs "$f" lib/*.sh $siblings | sort -u)
                for call in $(match -ohE '\bnh_[a-z0-9_]+' "$f" | sort -u); do
                  printf '%s\n' "$known" | grep -qx "$call" ||
                    { echo "$f calls $call, which neither it nor anything it sources defines" >&2; rc=1; }
                done
              done
              [ "$rc" -eq 0 ] || exit 1
              touch $out
            '';

          # The two Android profiles. An Android host's build product
          # is its plan, built on the seat that deploys it, so the
          # eval is keyed by this system and checked on every one the
          # CLI is packaged for. Building the kiosk plan fetches the
          # profile's APKs once per builder.
          fixture-kiosk = fixture.androidConfigurations.${system}.fixture-kiosk.config.system.build.plan;
          fixture-mobile = fixture.androidConfigurations.${system}.fixture-mobile.config.system.build.plan;

          # The checkout script against real git origins: what a
          # fixture host's eval cannot say is whether the script leaves
          # a repository's own .envrc alone.
          repositories-script = import ./checks/repositories-script.nix {
            pkgs = nixpkgs.legacyPackages.${system};
          };
        }
        // nixpkgs.lib.optionalAttrs (system == "x86_64-linux") {
          vm-oneshots = import ./checks/vm/oneshots.nix { pkgs = nixpkgs.legacyPackages.${system}; };

          # The one check that boots a guest ("Guests"): the fixtures
          # below read the machine's rendering, this one runs it.
          vm-guest = import ./checks/vm/guest.nix { inherit nixpkgs system; };

          # The fleet's own assertions, run rather than evaluated
          # ("Provisioning": Checks are units too): one check that
          # passes, one that fails, and the glob both verbs read them
          # through.
          vm-checks = import ./checks/vm/checks.nix { pkgs = nixpkgs.legacyPackages.${system}; };

          # The syncthing identity: one ciphertext, two files, and the
          # device ID the fleet committed still the daemon's after a
          # boot.
          vm-syncthing = import ./checks/vm/syncthing.nix { pkgs = nixpkgs.legacyPackages.${system}; };

          fixture-server = fixture.nixosConfigurations.fixture-server.config.system.build.toplevel;

          # The internet-facing host. One caddy listener serves every
          # vhost, so the internet posture and the unauthenticated
          # tailnet one cannot share a host — the branches caddy and
          # the firewall take for an internet endpoint are only
          # reachable here.
          fixture-gateway = fixture.nixosConfigurations.fixture-gateway.config.system.build.toplevel;

          # The tailnet-only host. The framework's default SSH posture
          # — sshd NOT opened fleet-wide, port 22 scoped to the
          # tailscale interface, no fail2ban — is only reachable on a
          # host that is a member of no internet-typed network, which
          # neither of the two above is. Its stub module asserts each
          # of those, so this check fails if the scoping regresses.
          fixture-node = fixture.nixosConfigurations.fixture-node.config.system.build.toplevel;

          # The eval every fixture host is the passing half of: a
          # repository on a forge nothing pins must fail here rather
          # than become a retry loop on the seat.
          forge-pin = import ./checks/forge-pin.nix {
            inherit fixture;
            pkgs = nixpkgs.legacyPackages.${system};
          };

          # The desktop profile. The seat: graphics, audio, portals, nix-ld and
          # the wayland session environment are only reachable here —
          # every other NixOS fixture host is a server.
          fixture-desktop = fixture.nixosConfigurations.fixture-desktop.config.system.build.toplevel;

          # The guest ("Guests"): a server-profile host fixture-desktop
          # runs as a container. This toplevel IS the machine's
          # `containers.fixture-guest.path`, an equality the desktop
          # stub asserts, so the desktop check above builds exactly
          # this derivation, and this one reads the guest side of the
          # boundary through the guest stub's assertions. Both are
          # eval-only; `vm-guest` above boots the pair.
          fixture-guest = fixture.nixosConfigurations.fixture-guest.config.system.build.toplevel;

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
