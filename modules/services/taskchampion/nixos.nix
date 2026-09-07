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

  # A consistent copy of the state directory: sqlite files through
  # `.backup` (a plain cp of a live database can tear), everything
  # else copied as-is. Runs as root because the server is a
  # DynamicUser; the copy is handed to group `backups`.
  backup = pkgs.writeShellApplication {
    name = "backup-taskchampion";
    runtimeInputs = [
      pkgs.sqlite
      pkgs.coreutils
      pkgs.findutils
    ];
    text = ''
      src=${dataDir}
      dest=${toString cfg.backupDir}
      if [ ! -d "$src" ]; then
        echo "no data directory yet at $src" >&2
        exit 0
      fi
      umask 0027
      mkdir -p "$dest"
      find "$src" -mindepth 1 -maxdepth 1 -name '*.sqlite3*' -prune -o -print0 \
        | xargs -0 -r cp -a -t "$dest"
      for db in "$src"/*.sqlite3; do
        [ -e "$db" ] || continue
        sqlite3 "$db" ".backup '$dest/$(basename "$db")'"
      done
      # cp keeps the source modes (the server writes 0600) and umask
      # only ever removes bits, so group access is set explicitly;
      # symbolic chmod leaves the directory's setgid bit alone.
      chown -R root:backups "$dest"
      chmod -R u=rwX,g=rX,o= "$dest"
      chmod g+s "$dest"
    '';
  };
in
{
  imports = [ ./default.nix ];

  config = lib.mkMerge [
    { nixhold.services.taskchampion.implementation = "nixos"; }

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

        (lib.mkIf (cfg.backupDir != null) {
          # One group per data flow, never a shared "services" group
          # and never `users` (every human account's primary group, so
          # it grants nothing narrower than "any local login"). This
          # one carries the nightly copies off the box.
          users.groups.backups = { };

          systemd.services.backup-taskchampion = {
            description = "Backup taskchampion-sync-server";
            serviceConfig = {
              Type = "oneshot";
              ExecStart = lib.getExe backup;
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
