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

    # One row per guest, from the machine entries that name it. Each
    # guest gets one /24 out of 10.233.0.0/16, the range nixpkgs' own
    # container examples use: 10.233.<octet>.1 on the machine and .2
    # in the guest, the same value on both sides of the boundary
    # because both read it here.
    #
    # <octet> is derived from the guest's NAME: the first 32 bits of
    # its sha256 folded into 1..254. A position in the sorted list of
    # guests would renumber every guest that sorts after a newly added
    # one, moving live veths, their routes and the machine's NAT on a
    # deploy that was meant to add a host. Two guests of one machine
    # whose names land on the same octet is an eval assertion in
    # modules/guests/machine.nix.
    guests =
      let
        rows = lib.concatMap (
          machine:
          lib.mapAttrsToList (guest: grant: {
            name = guest;
            value = {
              inherit machine;
              inherit (grant) devices;
            };
          }) fleet.hosts.${machine}.guests
        ) (lib.attrNames fleet.hosts);
        # `listToAttrs` keeps the first definition of a duplicate key;
        # the machines are walked in name order, so it is the first
        # machine's.
        byGuest = lib.listToAttrs rows;
        hexValue = lib.listToAttrs (
          lib.imap0 (i: c: lib.nameValuePair c i) (lib.stringToCharacters "0123456789abcdef")
        );
        octet =
          guest:
          1
          + lib.mod (lib.foldl' (acc: c: acc * 16 + hexValue.${c}) 0 (
            lib.stringToCharacters (builtins.substring 0 8 (builtins.hashString "sha256" guest))
          )) 254;
      in
      lib.mapAttrs (
        guest: row:
        let
          n = toString (octet guest);
        in
        row
        // {
          hostAddress = "10.233.${n}.1";
          localAddress = "10.233.${n}.2";
        }
      ) byGuest;

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
