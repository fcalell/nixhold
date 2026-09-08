# Vaultwarden service — option namespace.
#
# Split from the implementation (./nixos.nix) for the reason spelled
# out in ../openssh/default.nix: the namespace is baseline-wide, the
# implementation is per-platform and profile-attached.
{ config, lib, ... }:
let
  cfg = config.nixhold.services.vaultwarden;
  types' = config.nixhold.types;
in
{
  options.nixhold.services.vaultwarden = {
    enable = lib.mkEnableOption "Vaultwarden (Bitwarden backend) behind caddy";

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
      example = "/var/lib/backups/vaultwarden";
      description = ''
        Where nixpkgs' daily backup timer (23:00, persistent) puts a
        consistent copy of the vault: a `sqlite3 .backup` of the
        database plus the attachments and RSA keys. The directory is
        group `backups` (setgid) and the files group-readable, so a
        sync service above it can carry the backup off the box.
        `backups` is the group for that one data flow. Null: no
        backup timer.
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
        The implementation declares the `web` endpoint whole —
        backend port, path prefix and the no-strip routing
        vaultwarden's `DOMAIN` needs — except for its `network`,
        which is fleet data: the host names the network it wants the
        vault reachable on (`expose.web.network = "tailnet"`).
      '';
    };
  };

  config.assertions = lib.optional (cfg.enable && cfg.implementation == null) {
    assertion = false;
    message = "nixhold.services.vaultwarden is enabled but no implementation is attached on this host — import `nixhold.modules.services.nixos.vaultwarden` (NixOS only).";
  };
}
