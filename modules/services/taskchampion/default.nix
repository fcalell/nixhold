# taskchampion-sync-server — option namespace.
#
# Split from the implementation (./nixos.nix) for the reason spelled
# out in ../openssh/default.nix: the namespace is baseline-wide, the
# implementation is per-platform and profile-attached.
{ config, lib, ... }:
let
  cfg = config.nixhold.services.taskchampion;
  types' = config.nixhold.types;
in
{
  options.nixhold.services.taskchampion = {
    enable = lib.mkEnableOption "taskchampion-sync-server (taskwarrior 3.x replication) behind caddy";

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

    backupDir = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/var/lib/backups/taskchampion";
      description = ''
        Where a daily timer (23:00, persistent) puts a consistent copy
        of the sync server's state directory, group `backups` and
        group-readable so a sync service above it carries it off the
        box — `backups` is the group for that one data flow. The
        content is client-side ciphertext. Null: no backup timer.
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
        The implementation declares the `sync` endpoint whole —
        backend port and path prefix — except for its `network`,
        which is fleet data: the host names the network it wants the
        sync server reachable on (`expose.sync.network = "tailnet"`).
      '';
    };
  };

  config.assertions = lib.optional (cfg.enable && cfg.implementation == null) {
    assertion = false;
    message = "nixhold.services.taskchampion is enabled but no implementation is attached on this host — import `nixhold.modules.services.taskchampion` (NixOS only).";
  };
}
