# taskchampion-sync-server — NixOS implementation.
#
# Plain HTTP on localhost; caddy fronts it at `<fqdn>/task` on
# whichever network the host names in `expose.sync.network`. Task data
# is E2E-encrypted client-side (encryption_secret in the taskwarrior
# config), so the server only stores ciphertext — no server secret.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.nixhold.services.taskchampion;
  dataDir = config.services.taskchampion-sync-server.dataDir;
  hardening = import ../../../lib/hardening.nix;

  # A consistent copy of the state directory: sqlite files through
  # `.backup` (a plain cp of a live database can tear), everything
  # else copied as-is. Runs as root because the server may be a
  # DynamicUser, whose uid exists only while it runs; publishing the
  # copy is the framework's (modules/infra/backups.nix).
  #
  # `cp -r`, not `cp -a`: the copies belong to the uid the backups
  # infra publishes them under, not to the server's, and their mtimes
  # are what the freshness check after the run reads.
  backup = pkgs.writeShellApplication {
    name = "backup-taskchampion";
    runtimeInputs = [
      pkgs.sqlite
      pkgs.coreutils
      pkgs.findutils
    ];
    text = ''
      src=${dataDir}
      dest=${toString cfg.backup.dir}
      if [ ! -e "$src" ]; then
        echo "no data directory yet at $src — the server has not run" >&2
        exit 0
      fi
      if [ ! -r "$src" ]; then
        echo "cannot read $src — this unit's capabilities no longer cover the server's state directory" >&2
        exit 1
      fi
      find "$src" -mindepth 1 -maxdepth 1 -name '*.sqlite3*' -prune -o -print0 \
        | xargs -0 -r cp -r -t "$dest"
      for db in "$src"/*.sqlite3; do
        [ -e "$db" ] || continue
        sqlite3 "$db" ".backup '$dest/$(basename "$db")'"
      done
    '';
  };
in
{
  imports = [ ./default.nix ];

  config = lib.mkMerge [
    {
      nixhold.services.taskchampion = {
        implementation = "nixos";
        # The producer below; root, since the server is a DynamicUser.
        backup.unit = "backup-taskchampion";
      };
    }

    (lib.mkIf cfg.enable (
      lib.mkMerge [
        {
          nixhold.services.taskchampion = {
            network.ports.sync = 8080;
            expose.sync = {
              protocol = "https";
              backend = "sync";
              pathPrefix = "/task";
              extraConfig = "encode zstd gzip";
            };
          };

          services.taskchampion-sync-server = {
            enable = true;
            host = "127.0.0.1";
            port = 8080;
          };
        }

        (lib.mkIf (cfg.backup.dir != null) {
          systemd.services.backup-taskchampion = {
            description = "Backup taskchampion-sync-server";
            serviceConfig = hardening // {
              Type = "oneshot";
              ExecStart = lib.getExe backup;
              # The source (sqlite opens a WAL database's -shm for
              # writing even to read it) and the copies. The `-`
              # prefix: the server's data directory does not exist
              # until its first start, and a missing ReadWritePaths
              # entry fails the namespace setup before the script's
              # own "not yet" guard can be reached.
              ReadWritePaths = [
                "-${dataDir}"
                cfg.backup.dir
              ];
              # The three the copier needs as a capability-less root
              # (lib/hardening.nix): the state directory is the
              # server's own uid and mode, sqlite writes the -shm of a
              # WAL database to read it, and — running as root — it
              # hands the -wal/-shm it creates to the database's owner,
              # so the server keeps writing its own journal after this
              # unit has been through it. Running as the owning user is
              # the alternative everywhere else; it is not one here,
              # because nixpkgs runs the server under a `DynamicUser`
              # (`services.taskchampion-sync-server.dynamicUser`, on
              # from stateVersion 26.05) whose uid is allocated at
              # start and is no name a unit can be given.
              CapabilityBoundingSet = [
                "CAP_DAC_READ_SEARCH"
                "CAP_DAC_OVERRIDE"
                "CAP_CHOWN"
              ];
              # That chown is `@privileged`, which the set filters —
              # and a filtered syscall is SIGSYS, so sqlite dies on it
              # instead of seeing the EPERM it would forgive.
              SystemCallFilter = hardening.SystemCallFilter ++ [ "@chown" ];
            };
          };
          systemd.timers.backup-taskchampion = {
            description = "Backup taskchampion-sync-server on time";
            wantedBy = [ "timers.target" ];
            timerConfig = {
              OnCalendar = "23:00";
              Persistent = true;
              Unit = "backup-taskchampion.service";
            };
          };
        })
      ]
    ))
  ];
}
