# OpenSSH service — NixOS implementation of the hardened preset.
#
# What `nixhold.modules.services.nixos.openssh` resolves to: a profile
# importing it gets the option namespace (./default.nix, the same
# module the services index attaches) plus the config below. Operator
# opts in with `nixhold.services.openssh.enable = true` (the `server`
# profile flips this on by default). The framework sets opinionated
# NixOS defaults; the operator can still override individual
# `services.openssh.settings.*` because the defaults use
# `lib.mkDefault`.
#
# Where sshd is REACHABLE follows from the fleet roster, not from a
# knob. A host on no internet-typed network has no business answering
# on 22 from the LAN it happens to sit on: the fleet reaches it over
# the tailnet, and `nixhold deploy` / `logs` / `host key` all go that
# way. So the global opening is dropped and 22 is opened on the
# tailscale interface alone — the same interface-scoping
# modules/infra/firewall.nix does for caddy's tailnet vhosts, read
# from the same `services.tailscale.interfaceName`.
#
# A host that IS on an internet network keeps the global opening (it is
# the gateway; that is the seat the operator reaches the fleet from
# when the tailnet is down) and gets fail2ban, unconditionally rather
# than per profile: an internet-facing sshd without one is not a
# posture the framework offers.
{ config, lib, ... }:
let
  cfg = config.nixhold.services.openssh;
  fleet = config.nixhold.fleet;

  # Same internet-vs-tailscale question modules/infra/firewall.nix
  # asks, one layer earlier: it reads the resolved endpoint list
  # (a host may be on an internet network and expose nothing), sshd
  # reads the host's own membership, because sshd is not an endpoint —
  # it answers wherever the interface it is opened on reaches.
  networksOf = if fleet.derived.self == null then [ ] else fleet.derived.self.networks;
  typeOf = n: (fleet.network.${n} or { type = null; }).type;
  onInternet = lib.any (n: typeOf n == "internet") networksOf;
in
{
  imports = [ ./default.nix ];

  config = lib.mkMerge [
    { nixhold.services.openssh.implementation = "nixos"; }

    (lib.mkIf cfg.enable {
      services.openssh = {
        enable = true;
        openFirewall = lib.mkDefault onInternet;
        settings = {
          PasswordAuthentication = lib.mkDefault false;
          KbdInteractiveAuthentication = lib.mkDefault false;
          PermitRootLogin = lib.mkDefault "prohibit-password";
          X11Forwarding = lib.mkDefault false;
        };
      };
    })

    (lib.mkIf (cfg.enable && !onInternet) {
      networking.firewall.interfaces.${config.services.tailscale.interfaceName}.allowedTCPPorts = [
        22
      ];
    })

    (lib.mkIf (cfg.enable && onInternet) {
      services.fail2ban.enable = lib.mkDefault true;
    })
  ];
}
