# Tailscale service — NixOS implementation.
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
in
{
  imports = [ ./default.nix ];

  config = lib.mkMerge [
    { nixhold.services.tailscale.implementation = "nixos"; }

    (lib.mkIf cfg.enable (
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
            description = "Tailscale pre-auth key (tskey-auth-…) — create at login.tailscale.com/admin/settings/keys";
          };
          services.tailscale.authKeyFile = config.age.secrets.${cfg.authKeySecret}.path;
          # nixpkgs' autoconnect sends the key once per state change and
          # otherwise waits for its start timeout, then fails for good:
          # a network that came up late, or a key the control plane had
          # not finished propagating, leaves the box off the tailnet on
          # the one boot that matters. Retry the way the tailnet cert
          # oneshot does; a spent key fails the same way each time and
          # is the operator's to replace.
          systemd.services.tailscaled-autoconnect.serviceConfig = {
            Restart = "on-failure";
            RestartSec = 30;
          };
        })
      ]
    ))
  ];
}
