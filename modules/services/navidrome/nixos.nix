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
    {
      nixhold.services.navidrome = {
        implementation = "nixos";
        # The daemon writes its own copies: no oneshot to publish
        # after, so the record names only the writer.
        backup.user = user;
      };
    }

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

        (lib.mkIf (cfg.backup.dir != null) {
          # Navidrome's own scheduler: an sqlite backup of the database
          # into the directory, pruned to the count. The unit binds the
          # path in by itself. No oneshot ends with the copy in place,
          # so publishing rests on the directory's default ACL.
          services.navidrome.settings.Backup = {
            Path = cfg.backup.dir;
            Schedule = "0 23 * * *";
            Count = 7;
          };
        })
      ]
    ))
  ];
}
