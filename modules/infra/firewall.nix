# Firewall infrastructure module. Walks
# `config.nixhold.services.*.expose`, finds endpoints on
# internet-typed networks, and opens 80/443. Tailscale-typed
# networks need no firewall opening — the daemon tunnels them.
# Localhost endpoints are skipped (loopback isn't filtered).
#
# Auto-activates from data; no enable knob.
{ config, lib, ... }:
let
  fleetNetworks = config.nixhold.fleet.network;

  endpoints = lib.concatMap (s: lib.attrValues (s.expose or { })) (
    lib.attrValues config.nixhold.services
  );

  hasInternetEndpoint = lib.any (
    e:
    let
      net = fleetNetworks.${e.network} or null;
    in
    net != null && net.type == "internet"
  ) endpoints;
in
{
  config = lib.mkIf hasInternetEndpoint {
    networking.firewall.allowedTCPPorts = [
      80
      443
    ];
  };
}
