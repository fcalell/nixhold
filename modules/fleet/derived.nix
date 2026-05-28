{ config, lib, ... }:
let
  fleet = config.nixhold.fleet;
  hostName = config.networking.hostName or null;
in
{
  config.nixhold.fleet.derived = {
    self = if hostName == null then null else fleet.hosts.${hostName} or null;

    publicHosts = lib.attrNames (
      lib.filterAttrs (_: h: h.publicIp != null) fleet.hosts
    );

    hostsByNetwork = lib.mapAttrs (
      netName: _:
      lib.attrNames (
        lib.filterAttrs (_: h: lib.elem netName h.networks) fleet.hosts
      )
    ) fleet.network;

    address = lib.mapAttrs (
      hostName: host:
      lib.mapAttrs (
        netName: net:
        if !(lib.elem netName host.networks) then
          null
        else if net.type == "tailscale" then
          if net.magicDnsSuffix == null then null else "${hostName}.${net.magicDnsSuffix}"
        else if net.type == "internet" then
          if host.publicFqdn != null then
            host.publicFqdn
          else if host.publicIp != null then
            host.publicIp
          else
            null
        else
          null
      ) fleet.network
    ) fleet.hosts;

    operatorAuthorizedKeys = lib.filter (k: k != null) (
      lib.mapAttrsToList (_: h: h.loginPubkey or null) fleet.hosts
    );
  };
}
