# Tailscale service.
#
# By default the framework supplies the daemon + firewall integration
# and joining is a one-time out-of-band `tailscale up` (auth against
# the operator's Tailscale account). Set `authKeySecret` to the name
# of a `nixhold.secrets.<name>` holding a pre-auth key (generated on
# the Tailscale admin console's Keys page) for unattended join on
# activation — the framework declares that secret and wires
# `services.tailscale.authKeyFile`. Bootstrap the key with
# `nixhold secret edit <host> <name>` before install.
{ config, lib, ... }:
let
  cfg = config.nixhold.services.tailscale;
  types' = config.nixhold.types;
in
{
  options.nixhold.services.tailscale = {
    enable = lib.mkEnableOption "the Tailscale daemon";

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

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        services.tailscale = {
          enable = true;
          openFirewall = lib.mkDefault true;
        };
      }

      (lib.mkIf (cfg.authKeySecret != null) {
        nixhold.secrets.${cfg.authKeySecret} = {
          owner = "root";
          mode = "0400";
          description = "Tailscale pre-auth key for unattended tailnet join.";
        };
        services.tailscale.authKeyFile = config.age.secrets.${cfg.authKeySecret}.path;
      })
    ]
  );
}
