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
  # else copied as-is. Runs as root because the server is a
  # DynamicUser; publishing the copy is the framework's
  # (modules/infra/backups.nix).
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
      if [ ! -d "$src" ]; then
        echo "no data directory yet at $src" >&2
        exit 0
      fi
      find "$src" -mindepth 1 -maxdepth 1 -name '*.sqlite3*' -prune -o -print0 \
        | xargs -0 -r cp -a -t "$dest"
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
              # writing even to read it) and the copies.
              ReadWritePaths = [
                dataDir
                cfg.backup.dir
              ];
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
