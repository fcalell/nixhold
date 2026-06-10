# Firewall infrastructure module. Walks
# `config.nixhold.services.*.expose`, finds endpoints on
# internet-typed networks, and opens 80/443. Tailscale-typed
# networks get 443 opened scoped to the tailscale interface only —
# the daemon tunnels the traffic, but the NixOS firewall still
# filters INPUT on `tailscale0` like any other interface
# (`services.tailscale.openFirewall` only opens the WireGuard UDP
# port), so caddy's tailnet vhosts need an explicit opening.
# Localhost endpoints are skipped (loopback isn't filtered).
#
# Auto-activates from data; no enable knob.
{ config, lib, ... }:
let
  fleetNetworks = config.nixhold.fleet.network;

  endpoints = lib.concatMap (s: lib.attrValues (s.expose or { })) (
    lib.attrValues (config.nixhold.services or { })
  );

  netTypeOf =
    e:
    let
      net = fleetNetworks.${e.network} or null;
    in
    if net == null then null else net.type;

  hasInternetEndpoint = lib.any (e: netTypeOf e == "internet") endpoints;
  hasTailscaleEndpoint = lib.any (e: netTypeOf e == "tailscale") endpoints;
in
{
  config = lib.mkMerge [
    (lib.mkIf hasInternetEndpoint {
      networking.firewall.allowedTCPPorts = [
        80
        443
      ];
    })

    # Interface-scoped so the LAN stays closed: only peers reaching
    # this host over the tailnet see the HTTPS listener.
    (lib.mkIf hasTailscaleEndpoint {
      networking.firewall.interfaces.${config.services.tailscale.interfaceName}.allowedTCPPorts =
        [ 443 ];
    })
  ];
}
