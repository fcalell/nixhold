# vm-guest: the check that BOOTS a guest ("Guests").
#
# The fixtures are eval-only: they read what a machine renders and
# every start-path bug is invisible to them. This one runs the
# framework's machine-side module on a NetworkManager seat (the
# machine kind where nothing but the container unit raises the host end
# of the veth) with a guest whose own readiness waits on that veth.
# That is the deadlock `modules/guests/machine.nix` sets the unit's
# Type and its veth wait to break, and a regression in either hangs
# this test where a fixture would still pass.
#
# The roster is hand-written rather than mkFleet's: the boundary reads
# `nixhold.fleet` and nothing else a baseline carries, and a VM that
# also booted tailscale, caddy and agenix would be testing those.
{ nixpkgs, system }:
let
  lib = nixpkgs.lib;
  pkgs = nixpkgs.legacyPackages.${system};

  # One machine, one guest of it, the same value both sides read, as
  # on a real fleet.
  roster = {
    network = { };
    hosts = {
      machine = {
        arch = system;
        guests.guest = { };
      };
      guest.arch = system;
    };
  };
  fleetModules = selfName: [
    ../../modules/layout
    ../../modules/fleet
    ../../modules/fleet/derived.nix
    {
      nixhold.fleet = roster // {
        inherit selfName;
      };
    }
  ];

  derived =
    (lib.evalModules { modules = fleetModules null; }).config.nixhold.fleet.derived.guests.guest;

  guest = nixpkgs.lib.nixosSystem {
    inherit system;
    modules = fleetModules "guest" ++ [
      ../../modules/guests/guest.nix
      (
        { pkgs, ... }:
        {
          networking.hostName = "guest";
          # networkd, as the server profile a real guest draws runs it:
          # its wait-online is half of the deadlock.
          networking.useNetworkd = true;
          system.stateVersion = "25.05";

          # Stands in for tailscaled-autoconnect, the other half: a unit
          # of the guest's initial transaction that cannot finish until
          # the machine has raised its end of the veth. Reaching the
          # machine is also the proof that the veth carries traffic.
          systemd.services.nixhold-vm-online = {
            description = "Reach the machine through the veth";
            wantedBy = [ "multi-user.target" ];
            wants = [ "network-online.target" ];
            after = [ "network-online.target" ];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
            };
            script = "${pkgs.iputils}/bin/ping -c 1 -w 30 ${derived.hostAddress}";
          };
        }
      )
    ];
  };
in
pkgs.testers.runNixOSTest {
  name = "nixhold-vm-guest";

  nodes.machine = {
    imports = fleetModules "machine" ++ [ ../../modules/guests/machine.nix ];

    # The seat's network manager, which leaves `ve-*` unmanaged and
    # raises nothing: the machine kind the start path exists for.
    networking.networkmanager.enable = true;

    containers.guest.path = guest.config.system.build.toplevel;

    # The boundary binds /etc/nixhold in, and on a real machine
    # `nixhold deploy` puts the fleet key there before any guest
    # starts. This VM has no fleet, so the directory is made empty:
    # nspawn refuses to bind a path that is not there.
    systemd.tmpfiles.rules = [ "d /etc/nixhold 0700 root root -" ];

    virtualisation.memorySize = 2048;
    system.stateVersion = "25.05";
  };

  testScript = ''
    machine.wait_for_unit("multi-user.target")

    with subtest("the container unit comes up without waiting for the guest"):
        # Type=notify plus nixpkgs' post-start is the deadlock: the unit
        # would sit in `activating` until its start timeout cut it.
        machine.wait_for_unit("container@guest.service", timeout=120)
        machine.succeed("ip link show ve-guest")

    with subtest("the guest finishes booting"):
        # The same command `nixhold deploy` runs, and for the same
        # reason: an active container unit says nspawn was exec'd and
        # nothing about the system inside it.
        state = machine.succeed(
            "timeout 120 sh -c '"
            "until systemctl --machine guest show --property=Version >/dev/null 2>&1; do sleep 2; done; "
            "exec systemctl is-system-running --machine guest --wait' || true"
        ).strip()
        assert state in ("running", "degraded"), f"the guest reached '{state}'"

    with subtest("the veth carries traffic both ways"):
        # The guest's own unit pinged the machine; the machine pings back.
        machine.succeed("systemctl --machine guest is-active nixhold-vm-online.service")
        machine.succeed("ping -c 1 -w 30 ${derived.localAddress}")
  '';
}
