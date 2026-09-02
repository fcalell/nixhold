# Firewall infrastructure module. Reads the same resolved endpoint
# list caddy serves (`nixhold.infra.endpoints`, derived once in
# ./endpoints.nix) and opens the HTTP ports for it — never for an
# endpoint caddy would not serve, which is what re-walking
# `nixhold.services` with its own looser predicates used to do.
#
# Internet-typed networks get 80/443 opened globally. Tailscale-typed
# networks get 443 opened scoped to the tailscale interface only — the
# daemon tunnels the traffic, but the NixOS firewall still filters
# INPUT on `tailscale0` like any other interface
# (`services.tailscale.openFirewall` only opens the WireGuard UDP
# port), so caddy's tailnet vhosts need an explicit opening.
# Localhost endpoints never reach this list (loopback isn't filtered).
#
# UDP 443 rides along with TCP in both branches: caddy binds QUIC on
# the HTTPS port and advertises HTTP/3 via Alt-Svc, so a client that
# takes the offer stalls until it falls back if UDP is dropped.
#
# Auto-activates from data; no enable knob.
{ config, lib, ... }:
let
  endpoints = config.nixhold.infra.endpoints;

  hasInternetEndpoint = lib.any (e: e.netType == "internet") endpoints;
  hasTailscaleEndpoint = lib.any (e: e.netType == "tailscale") endpoints;
in
{
  imports = [ ./endpoints.nix ];

  config = lib.mkMerge [
    (lib.mkIf hasInternetEndpoint {
      networking.firewall.allowedTCPPorts = [
        80
        443
      ];
      networking.firewall.allowedUDPPorts = [ 443 ];
    })

    # Interface-scoped so the LAN stays closed: only peers reaching
    # this host over the tailnet see the HTTPS listener. Note this
    # scoping is the *only* thing that keeps a tailnet vhost off the
    # LAN — caddy itself listens on every address — which is why
    # caddy.nix refuses a host that mixes internet endpoints with
    # unauthenticated tailnet ones.
    (lib.mkIf hasTailscaleEndpoint {
      networking.firewall.interfaces.${config.services.tailscale.interfaceName} = {
        allowedTCPPorts = [ 443 ];
        allowedUDPPorts = [ 443 ];
      };
    })
  ];
}
