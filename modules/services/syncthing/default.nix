# Syncthing — option namespace.
#
# Split from the implementation (./nixos.nix) for the reason spelled
# out in ../openssh/default.nix: the namespace is baseline-wide, the
# implementation is per-platform and profile-attached.
{ config, lib, ... }:
let
  cfg = config.nixhold.services.syncthing;
  types' = config.nixhold.types;
in
{
  options.nixhold.services.syncthing = {
    enable = lib.mkEnableOption "Syncthing, GUI behind caddy and sync over the tailnet";

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

    network = lib.mkOption {
      type = types'.network;
      default = { };
    };

    expose = lib.mkOption {
      type = types'.expose;
      default = { };
      description = ''
        The implementation declares the `gui` endpoint whole —
        backend port and path prefix — except for its `network`,
        which is fleet data: the host names the network it wants the
        GUI reachable on (`expose.gui.network = "tailnet"`). The sync
        protocol itself is not an endpoint (it is not HTTP); its
        ports are opened on the tailscale interface directly.
      '';
    };
  };

  config.assertions = lib.optional (cfg.enable && cfg.implementation == null) {
    assertion = false;
    message = "nixhold.services.syncthing is enabled but no implementation is attached on this host — import `nixhold.modules.services.syncthing` (NixOS only).";
  };
}
