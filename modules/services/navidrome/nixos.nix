# Navidrome — NixOS implementation.
#
# Reachable behind caddy at `<fqdn>/music` on whichever network the
# host names in `expose.web.network`; on a tailscale network that is
# the node's own MagicDNS name with the tailscale-issued cert (see
# ARCHITECTURE "Tailnet TLS").
#
# Identity is the tailnet's: Navidrome trusts the user header caddy
# sets from tailscale's auth daemon (`Tailscale-Login`, the login
# without its domain) and creates users from it, the first one admin.
# That trust is only sound if nothing but caddy can reach the
# listener, so the listener is a unix socket that admits caddy's group
# and nobody else (ARCHITECTURE "Socket backends") and Navidrome's
# trusted-source list is `@`, its name for "the socket's peer". The
# Subsonic API (`/music/rest`) ignores the header by design — Subsonic
# clients carry their own Navidrome credentials — and sits behind the
# same node-identity gate as everything else on the endpoint.
{
  config,
  lib,
  ...
}:
let
  cfg = config.nixhold.services.navidrome;
  user = config.services.navidrome.user;

  # The socket lives outside `/run/navidrome`, which nixpkgs' unit
  # makes the process's private root (RootDirectory) and recreates on
  # every start, so its directory is bound in by path instead.
  socketDir = "/run/navidrome-web";
  socket = "${socketDir}/http.sock";
in
{
  imports = [ ./default.nix ];

  config = lib.mkMerge [
    { nixhold.services.navidrome.implementation = "nixos"; }

    (lib.mkIf cfg.enable (
      lib.mkMerge [
        {
          nixhold.services.navidrome = {
            network.sockets.web = socket;
            expose.web = {
              protocol = "https";
              backend = "web";
              pathPrefix = "/music";
              # With a BaseUrl, Navidrome mounts ALL routes under it
              # and expects the prefix passed through — so no
              # stripping (caddy `handle`, not `handle_path`).
              stripPrefix = false;
              extraConfig = "encode zstd gzip";
            };
          };

          services.navidrome = {
            enable = true;
            settings = {
              Address = "unix:${socket}";
              # Navidrome chmods the socket to this after binding, so
              # the unit's 0066 umask does not close it to caddy. Its
              # group is caddy's by inheritance from the setgid
              # directory below.
              UnixSocketPerm = "0660";
              BaseUrl = cfg.expose.web.pathPrefix;
              MusicFolder = toString cfg.musicDir;
              ExtAuth = {
                TrustedSources = "@";
                UserHeader = "Tailscale-Login";
              };
            };
          };

          # Owner rwx so Navidrome can replace a stale socket, caddy's
          # group traverse-only, and setgid so the socket Navidrome
          # creates lands in that group: the kernel gives a new inode
          # the group of a setgid directory, and a bound unix socket
          # is a new inode.
          systemd.tmpfiles.settings."10-navidrome".${socketDir}.d = {
            inherit user;
            group = config.services.caddy.group;
            mode = "2710";
          };
          systemd.services.navidrome.serviceConfig.BindPaths = [ socketDir ];
        }

        (lib.mkIf (cfg.backupDir != null) {
          # Navidrome's own scheduler: an sqlite backup of the database
          # into the directory, pruned to the count. The unit binds the
          # path in by itself.
          services.navidrome.settings.Backup = {
            Path = cfg.backupDir;
            Schedule = "0 23 * * *";
            Count = 7;
          };

          # One group per data flow, never a shared "services" group
          # and never `users` (which is every human account's primary
          # group, so it grants nothing narrower than "any local
          # login"). This one carries the nightly copies to whatever
          # syncs them off the box.
          users.groups.backups = { };

          systemd.tmpfiles.settings."10-navidrome" = {
            ${cfg.backupDir} = {
              # Setgid so every copy lands in `backups`. The writer
              # runs under a 0066 umask, which would make each copy
              # 0600; a default ACL on the directory replaces the
              # umask for files created in it, and this one grants the
              # group read and nothing more. Symbolic ACL, no `x`: the
              # copies are files.
              d = {
                inherit user;
                group = "backups";
                mode = "2750";
              };
              "a+".argument = "d:g:backups:r";
            };
            # The backup runs as navidrome (nixpkgs' unit: no
            # supplementary groups), so the parent has to be
            # traversable by that uid. The consumer owns the parent
            # and typically closes it to a group the writer is not in
            # (`backups` is the readers' group, not the writers'), so
            # the module adds the one bit the writer needs as an ACL:
            # execute only, on the immediate parent, appended to
            # whatever the consumer's own rule set. tmpfiles lets a
            # `+` type share a path with another file's `d` line and
            # runs the two in file order, so the parent's rule must
            # sort before `10-navidrome`. The parent must exist: this
            # line never creates it.
            ${dirOf cfg.backupDir}."a+".argument = "u:${user}:x";
          };
        })
      ]
    ))
  ];
}
