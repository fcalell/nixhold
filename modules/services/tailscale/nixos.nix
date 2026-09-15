# Tailscale service — NixOS implementation.
#
# By default the framework supplies the daemon + firewall integration
# and joining is a one-time out-of-band `tailscale up` (auth against
# the operator's Tailscale account). Set `authKeySecret` to the name
# of a `nixhold.secrets.<name>` holding a pre-auth key for unattended
# join on activation — the framework declares that secret and wires
# `services.tailscale.authKeyFile`.
#
# The declaration carries `tailscaleAuthKey`, the host's one
# tailscale-typed network, and that is what decides where the key
# comes from: the CLI mints it through the network's API client when
# the fleet commits one at keys/networks/<network>.age, and otherwise
# the operator pastes one from the admin console's Keys page. Either
# way `nixhold secret edit <host> <name>` is the verb.
{ config, lib, ... }:
let
  cfg = config.nixhold.services.tailscale;
  fleet = config.nixhold.fleet;
  # The tailscale-typed networks THIS host is on. One auth key joins
  # one tailnet, so the mint needs exactly one of them to name.
  tailnets = lib.filter (
    n: (fleet.network.${n} or null) != null && fleet.network.${n}.type == "tailscale"
  ) (if fleet.derived.self == null then [ ] else fleet.derived.self.networks);
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
            category = "service";
            description = "Tailscale pre-auth key (tskey-auth-…) — minted through the tailnet's API client, or created at login.tailscale.com/admin/settings/keys";
            # null when the host is on no single tailnet, which the
            # assertion below is what reports: the CLI then finds no
            # network to mint through and falls back to the editor.
            tailscaleAuthKey = if lib.length tailnets == 1 then lib.head tailnets else null;
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

          assertions = [
            {
              assertion = lib.length tailnets == 1;
              message = ''
                nixhold.services.tailscale.authKeySecret is set on a host
                whose `networks` name ${toString (lib.length tailnets)}
                tailscale-typed networks (${lib.concatStringsSep ", " tailnets}).
                An auth key joins one tailnet: list exactly one in the
                host's roster entry, or leave authKeySecret null and join
                by hand with `tailscale up`.
              '';
            }
          ];
        })
      ]
    ))
  ];
}
