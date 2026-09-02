# Fleet-wide SSH host-key pinning.
#
# Every host's public host key is already committed at
# `keys/hosts/<host>/host.pub` (the CLI writes it when the host is
# added; the secrets module encrypts to it). Without this module the
# operator's `ssh <peer>` is trust-on-first-use: a re-imaged box, or
# anything that answers to a squatted MagicDNS name, is accepted on
# sight. Here that same committed data becomes a system-wide
# `ssh_known_hosts` entry, so the peer's identity is decided in the
# repo rather than at the first connection.
#
# Data-driven like the rest of the fleet layer: no options to enable,
# nothing to wire per host. A host with no committed `host.pub` (added
# but not yet keyed) is simply absent — lint flags the missing key.
{ config, lib, ... }:
let
  inherit (lib) mkOption types;

  fleet = config.nixhold.fleet;

  # Same reader the fleet layer uses for `loginPubkey`.
  pubkeyLine = import ../../lib/pubkey-line.nix "nixhold.fleet.hostPubkey";

  hostPubPath = host: config.nixhold.layout.keysDir + "/hosts/${host}/host.pub";

  # Names this host answers to: every address it is reachable at on
  # any fleet network, plus the bare fleet key (which is both the
  # MagicDNS short name and what the ssh client matchBlock in
  # modules/home/common.nix is keyed by).
  hostNamesOf =
    host:
    lib.unique ([ host ] ++ lib.filter (a: a != null) (lib.attrValues fleet.derived.address.${host}));
in
{
  options.nixhold.fleet.hostPubkey = mkOption {
    type = types.attrsOf (types.nullOr types.str);
    readOnly = true;
    description = ''
      Per-host committed SSH host pubkey line, read from
      `keys/hosts/<host>/host.pub`, or `null` for a host whose key
      has not been committed yet. The single place the framework
      decides whether a fleet host's identity is pinnable: this
      module turns non-null entries into
      `programs.ssh.knownHosts`, and the home ssh client config
      turns them into `StrictHostKeyChecking = "yes"` on that
      peer's block.

      This host is included alongside its peers — pinning your own
      key costs nothing and makes `ssh <self>` behave like every
      other name.
    '';
  };

  config = {
    nixhold.fleet.hostPubkey = lib.mapAttrs (
      host: _:
      let
        p = hostPubPath host;
      in
      if builtins.pathExists p then pubkeyLine p else null
    ) fleet.hosts;

    programs.ssh.knownHosts = lib.mapAttrs (host: key: {
      hostNames = hostNamesOf host;
      publicKey = key;
    }) (lib.filterAttrs (_: key: key != null) fleet.hostPubkey);
  };
}
