{ config, lib, ... }:
let
  fleet = config.nixhold.fleet;

  # Every key line in the committed login file — the operator reaches
  # their own hosts by however many keys they carry (one per hardware
  # token, or the fleet's own key on a fleet with no token), and each
  # line is authorized on its own.
  pubkeyLines = import ../../lib/pubkey-lines.nix;
  loginPubPath = config.nixhold.layout.keysDir + "/login.pub";
in
{
  config.nixhold.fleet.derived = {
    # Keyed off the fleet attribute name, never the OS hostname —
    # see the `nixhold.fleet.selfName` description.
    self = if fleet.selfName == null then null else fleet.hosts.${fleet.selfName} or null;

    publicHosts = lib.attrNames (lib.filterAttrs (_: h: h.publicIp != null) fleet.hosts);

    hostsByNetwork = lib.mapAttrs (
      netName: _: lib.attrNames (lib.filterAttrs (_: h: lib.elem netName h.networks) fleet.hosts)
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

    # One file, one answer. No login key is any host's property — the
    # private halves live on hardware the fleet does not hold, or (on
    # a fleet with no token) in the one `identity` secret every host
    # already shares — so there is nothing per-host to aggregate.
    # Absent file means an empty list, not an eval error: a fleet
    # evaluates before its first key is committed, and lint is what
    # says the hosts authorize nobody.
    #
    # Same named principle-14 exception as the other committed-pubkey
    # readers: the path is computed off `keysDir`, and `pathExists`
    # only answers whether that one computed path is populated.
    operatorAuthorizedKeys = lib.unique (
      if builtins.pathExists loginPubPath then pubkeyLines loginPubPath else [ ]
    );
  };
}
