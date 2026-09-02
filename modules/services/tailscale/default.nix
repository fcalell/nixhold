# Tailscale service — option namespace.
#
# Split from the implementation (./nixos.nix) for the reason spelled
# out in ../openssh/default.nix: the namespace is baseline-wide,
# the implementation is per-platform and profile-attached.
{ config, lib, ... }:
let
  cfg = config.nixhold.services.tailscale;
  types' = config.nixhold.types;
in
{
  options.nixhold.services.tailscale = {
    enable = lib.mkEnableOption "the Tailscale daemon";

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

    authKeySecret = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Name of a `nixhold.secrets.<name>` holding a Tailscale
        pre-auth key. When set, the framework declares that secret
        (owner root, 0400) and points
        `services.tailscale.authKeyFile` at it, so the host
        auto-joins the tailnet on activation. `null` (default) leaves
        joining to a manual `tailscale up`. Pre-auth keys expire, so a
        stored key is mainly a first-boot convenience.
      '';
      example = "tailscale-authkey";
    };

    network = lib.mkOption {
      type = types'.network;
      default = { };
    };
    expose = lib.mkOption {
      type = types'.expose;
      default = { };
      description = ''
        Tailscale does not produce HTTP endpoints; this option
        exists for shape consistency.
      '';
    };
  };

  config.assertions = lib.optional (cfg.enable && cfg.implementation == null) {
    assertion = false;
    message = "nixhold.services.tailscale is enabled but no implementation is attached on this host — import `nixhold.modules.services.tailscale` (NixOS only).";
  };
}
