# The framework's oneshots, run rather than evaluated. The fixture in
# ../fixture is eval-only, and every failure this covers is a runtime
# one: a unit that builds, activates and then cannot read or write
# what its job is (the hardening set leaves a unit at uid 0 with no
# capability), or a producer that copies nothing and exits 0.
#
# One node carries all four shapes: caddy with a tailnet vhost whose
# cert comes from `tailscale cert` (a stub on the unit's PATH, since
# no VM joins a tailnet), a shipped service with a `backup.dir`
# (taskchampion, whose source is another uid's state directory), a
# fleet-local producer in the shape a forker writes one — a
# DynamicUser server behind a 0700 state directory with a root
# oneshot copying its database, which is the homelab's remux — and a
# pre-start that decides a setting from state no eval can see:
# vaultwarden's signups, read off its own database.
#
# The module list is the handful the units come from, not a fleet:
# mkFleet's baseline would bring provisioning and a tailnet join,
# neither of which any of these units reads. The secrets baseline is
# here for its option declarations alone — vaultwarden declares a
# secret — with no agenix activation behind it.
{ pkgs }:
let
  hardening = import ../../lib/hardening.nix;

  # Stands in for `tailscale cert`: writes the pair the real one
  # would, so caddy has a loadable vhost. `status` is the wait loop's
  # probe.
  tailscaleStub = pkgs.writeShellScriptBin "tailscale" ''
    set -eu
    verb="$1"
    shift
    [ "$verb" = "cert" ] || exit 0
    cert="" key="" fqdn=""
    for arg; do
      case "$arg" in
        --cert-file=*) cert="''${arg#*=}" ;;
        --key-file=*) key="''${arg#*=}" ;;
        *) fqdn="$arg" ;;
      esac
    done
    ${pkgs.openssl}/bin/openssl req -x509 -newkey rsa:2048 -noenc -days 1 \
      -subj "/CN=$fqdn" -keyout "$key" -out "$cert" 2>/dev/null
  '';

  producerState = "/var/lib/vm-producer";
in
pkgs.testers.runNixOSTest {
  name = "nixhold-oneshots";

  nodes.machine =
    { config, lib, ... }:
    {
      imports = [
        ../../modules/types
        ../../modules/fleet
        ../../modules/services
        ../../modules/infra/backups.nix
        ../../modules/infra/caddy.nix
        ../../modules/services/taskchampion/nixos.nix
        ../../modules/secrets/default.nix
        ../../modules/services/vaultwarden/nixos.nix
      ];

      # A fleet-local service: it publishes the record and owns its
      # producer, the framework owns the directory and the checks.
      options.nixhold.services = {
        vm-producer.backup = lib.mkOption {
          type = config.nixhold.types.backup;
          default = { };
        };
        vm-idle.backup = lib.mkOption {
          type = config.nixhold.types.backup;
          default = { };
        };
      };

      config = {
        # The one fleet fact the endpoint model needs: a network to
        # resolve the vhost's FQDN against.
        nixhold.fleet.network.tailnet = {
          type = "tailscale";
          magicDnsSuffix = "vm.ts.net";
        };

        # `auth = false`: the identity daemon is a tailnet of its own
        # to stand up, and what is under test is the cert, not the
        # gate.
        nixhold.services.taskchampion = {
          enable = true;
          expose.sync = {
            network = "tailnet";
            auth = false;
          };
          backup.dir = "/var/lib/backups/taskchampion";
        };

        # Vaultwarden, for the start-time decision its signups hang
        # on: the pre-start reads the database and the unit reads the
        # answer back as its last environment file. `auth = false`
        # for the same reason as above.
        nixhold.services.vaultwarden = {
          enable = true;
          expose.web = {
            network = "tailnet";
            auth = false;
          };
        };

        systemd.services.tailscale-caddy-cert.path = lib.mkBefore [ tailscaleStub ];

        nixhold.services.vm-producer.backup = {
          dir = "/var/lib/backups/vm-producer";
          unit = "backup-vm-producer";
        };

        systemd.services.vm-producer = {
          description = "A server whose state is its own uid's";
          wantedBy = [ "multi-user.target" ];
          serviceConfig = hardening // {
            Type = "oneshot";
            RemainAfterExit = true;
            DynamicUser = true;
            StateDirectory = "vm-producer";
            StateDirectoryMode = "0700";
            # WAL, like every database a producer here copies: the
            # -shm the copier's own open creates is what its caps are
            # for.
            ExecStart = "${pkgs.sqlite}/bin/sqlite3 ${producerState}/db.sqlite 'pragma journal_mode=wal; create table if not exists t (x); insert into t values (1);'";
          };
        };

        systemd.services.backup-vm-producer = {
          description = "Backup the fleet-local producer's database";
          serviceConfig = hardening // {
            Type = "oneshot";
            ExecStart = "${pkgs.sqlite}/bin/sqlite3 ${producerState}/db.sqlite \".backup '/var/lib/backups/vm-producer/db.sqlite'\"";
            ReadWritePaths = [
              "-${producerState}"
              "/var/lib/backups/vm-producer"
            ];
            # Named, with the reason: the source directory is 0700
            # under another uid, sqlite writes a WAL database's -shm
            # to read it, and as root it hands that -shm back to the
            # database's owner (`@chown` is filtered by the set, and a
            # filtered syscall is SIGSYS rather than EPERM).
            CapabilityBoundingSet = [
              "CAP_DAC_READ_SEARCH"
              "CAP_DAC_OVERRIDE"
              "CAP_CHOWN"
            ];
            SystemCallFilter = hardening.SystemCallFilter ++ [ "@chown" ];
          };
        };

        # The silent no-op the freshness check exists for: a producer
        # that exits 0 having copied nothing.
        nixhold.services.vm-idle.backup = {
          dir = "/var/lib/backups/vm-idle";
          unit = "backup-vm-idle";
        };
        systemd.services.backup-vm-idle.serviceConfig = hardening // {
          Type = "oneshot";
          ExecStart = "${pkgs.coreutils}/bin/true";
          ReadWritePaths = [ "/var/lib/backups/vm-idle" ];
        };
      };
    };

  testScript = ''
    machine.wait_for_unit("multi-user.target")

    # The tailnet cert: fetched by caddy's own uid, landing as the
    # pair caddy's vhost hard-references, and loadable — caddy is
    # brought up by the path unit's reload-or-restart, not its own
    # restart policy.
    machine.succeed("systemctl start tailscale-caddy-cert.service")
    machine.succeed(
        "stat -c '%U:%G %a' /var/lib/caddy/tls/cert.crt | grep -x 'caddy:caddy 640'"
    )
    machine.succeed(
        "stat -c '%U:%G %a' /var/lib/caddy/tls/cert.key | grep -x 'caddy:caddy 600'"
    )
    machine.wait_for_unit("caddy.service")

    # Vaultwarden decides its signups at start, off its own database:
    # with no account yet (no database at all here) the pre-start
    # opens the window, in the file the unit reads last.
    machine.wait_for_unit("vaultwarden.service")
    machine.succeed("grep -qx SIGNUPS_ALLOWED=true /run/vaultwarden/first-run.env")

    # And the half that closes it: run the same pre-start against a
    # database that HAS an account, and it writes the file empty, so
    # the unit's own SIGNUPS_ALLOWED=false is what is left standing.
    prestart = machine.succeed(
        "systemctl show -p ExecStartPre --value vaultwarden.service"
        " | grep -o '/nix/store/[^ ;]*-vaultwarden-first-run' | head -1"
    ).strip()
    machine.succeed("mkdir -p /tmp/vw/run /tmp/vw/data")
    machine.succeed(
        "${pkgs.sqlite}/bin/sqlite3 /tmp/vw/data/db.sqlite3"
        " 'create table users (x); insert into users values (1);'"
    )
    machine.succeed(
        f"RUNTIME_DIRECTORY=/tmp/vw/run DATA_FOLDER=/tmp/vw/data {prestart}"
    )
    machine.succeed("test ! -s /tmp/vw/run/first-run.env")

    # Both copiers: the run succeeds, it leaves a copy behind, and the
    # copy is published — group `backups`, 0640.
    for unit, d in [
        ("backup-taskchampion", "/var/lib/backups/taskchampion"),
        ("backup-vm-producer", "/var/lib/backups/vm-producer"),
    ]:
        machine.succeed(f"systemctl start {unit}.service")
        machine.succeed(f"test -n \"$(find {d} -type f)\"")
        machine.succeed(
            f"test -z \"$(find {d} ! -type d -printf '%g %m\\n' | sort -u | grep -v '^backups 640$')\""
        )

    # A producer that writes nothing is a failed unit, not a silent
    # success — and the freshness check is what fails it.
    machine.fail("systemctl start backup-vm-idle.service")
    machine.succeed("systemctl is-failed backup-vm-idle.service")
    machine.succeed(
        "journalctl -u backup-vm-idle.service | grep -q 'produced no copy'"
    )
  '';
}
