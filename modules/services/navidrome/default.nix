# Navidrome service — option namespace.
#
# Split from the implementation (./nixos.nix) for the reason spelled
# out in ../openssh/default.nix: the namespace is baseline-wide, the
# implementation is per-platform and profile-attached.
{ config, lib, ... }:
let
  cfg = config.nixhold.services.navidrome;
  types' = config.nixhold.types;
in
{
  options.nixhold.services.navidrome = {
    enable = lib.mkEnableOption "Navidrome (music server, Subsonic API) behind caddy";

    implementation = lib.mkOption {
      internal = true;
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Set by the platform implementation module when one is
        attached. Enabling a service whose implementation this host
        never imported would otherwise be a silent no-op.
      '';
    };

    musicDir = lib.mkOption {
      type = lib.types.path;
      example = "/srv/music";
      description = ''
        The library. The consumer owns the directory and whatever
        fills it; the service reads it as user `navidrome` and sees
        nothing else of the filesystem (nixpkgs' unit binds it
        read-only into a private root, and `ProtectHome` hides
        anything under `/home`), so the consumer makes it readable to
        that user. nixpkgs creates it `0700 navidrome` when it does
        not exist, so a consumer that fills it later creates it
        first.
      '';
    };

    backupDir = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/var/lib/backups/navidrome";
      description = ''
        Where Navidrome's own nightly backup (23:00, the last seven
        kept) puts a consistent copy of its database, which is
        everything but the music: users, play counts, playlists,
        stars. The directory is group `backups` (setgid) and the
        copies group-readable, so a sync service above it can carry
        them off the box. `backups` is the group for that one data
        flow. The parent directory is the consumer's; it must exist
        (its tmpfiles rule sorting before `10-navidrome`) and it gets
        an execute-only ACL for user `navidrome`, the writer's uid, so
        the consumer can close the parent to any group without
        locking the writer out. Null: no backups.
      '';
    };

    network = lib.mkOption {
      type = types'.network;
      default = { };
    };

    expose = lib.mkOption {
      type = types'.expose;
      default = { };
      description = ''
        The implementation declares the `web` endpoint whole — the
        unix-socket backend, the `/music` prefix Navidrome mounts
        every route under and the no-strip routing that needs —
        except for its `network`, which is fleet data: the host names
        the network it wants the music reachable on
        (`expose.web.network = "tailnet"`). The Subsonic API rides
        the same endpoint at `<prefix>/rest`.
      '';
    };
  };

  config.assertions = lib.optional (cfg.enable && cfg.implementation == null) {
    assertion = false;
    message = "nixhold.services.navidrome is enabled but no implementation is attached on this host — import `nixhold.modules.services.nixos.navidrome` (NixOS only).";
  };
}
