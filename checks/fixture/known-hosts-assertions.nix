# Fixture coverage for fleet host-key pinning
# (modules/fleet/known-hosts.nix + the ssh client half in
# modules/home/common.nix). Imported by both fixture hosts, so the
# same expectations are checked from the NixOS side and the darwin
# side — the two platforms declare `programs.ssh.knownHosts`
# separately, and a shape drift between them would otherwise only
# show up on a real Mac.
#
# The fixture commits a host key for `fixture-server` only, so it
# covers both branches at once: the pinned peer (seen from
# fixture-mac) and the unpinned one (fixture-mac, seen from
# fixture-server).
{ config, lib, ... }:
let
  fleet = config.nixhold.fleet;
  knownHosts = config.programs.ssh.knownHosts;

  # Read independently of the module under test: if the layout
  # defaults ever stop resolving to the fixture's keys/ tree, the
  # comparison below fails instead of quietly comparing null to null.
  committedServerKey = lib.removeSuffix "\n" (builtins.readFile ./keys/hosts/fixture-server/host.pub);

  hmSettings = config.home-manager.users.${config.nixhold.identity.username}.programs.ssh.settings;
  # `settings` also carries HM's own `"*"` block; only fleet peers
  # are ours to make claims about.
  peerBlocks = lib.filterAttrs (name: _: lib.hasAttr name fleet.hosts) hmSettings;

  sorted = lib.sort (a: b: a < b);
in
{
  assertions = [
    {
      assertion = fleet.hostPubkey.fixture-server == committedServerKey;
      message = "fixture: nixhold.fleet.hostPubkey.fixture-server did not read keys/hosts/fixture-server/host.pub";
    }
    {
      assertion = fleet.hostPubkey.fixture-mac == null;
      message = "fixture: fixture-mac has no committed host.pub, so its hostPubkey must be null";
    }
    {
      assertion = (knownHosts.fixture-server or null) != null;
      message = "fixture: programs.ssh.knownHosts is missing the fixture-server pin";
    }
    {
      assertion = knownHosts.fixture-server.publicKey == committedServerKey;
      message = "fixture: knownHosts.fixture-server pins the wrong key";
    }
    {
      # Bare fleet key + every address the host is reachable at, on
      # both of its networks.
      assertion =
        sorted knownHosts.fixture-server.hostNames == sorted [
          "fixture-server"
          "fixture-server.fixture.ts.net"
          "fixture-server.fixture.example.invalid"
        ];
      message = "fixture: knownHosts.fixture-server.hostNames = ${builtins.toJSON knownHosts.fixture-server.hostNames}";
    }
    {
      assertion = !(knownHosts ? fixture-mac);
      message = "fixture: fixture-mac has no committed host key and must not be pinned";
    }
    {
      assertion = peerBlocks != { };
      message = "fixture: no fleet-peer ssh matchBlock was emitted — the client-side check below is vacuous";
    }
    {
      # The client half must track the pin exactly: pinned peers get
      # `StrictHostKeyChecking = "yes"`, unpinned peers keep ssh's
      # default (the directive absent).
      assertion = lib.all (
        peer:
        (peerBlocks.${peer}.data.StrictHostKeyChecking or null)
        == (if fleet.hostPubkey.${peer} == null then null else "yes")
      ) (lib.attrNames peerBlocks);
      message = "fixture: StrictHostKeyChecking on the fleet-peer ssh blocks does not match which peers are pinned";
    }
  ]
  ++ lib.optional (peerBlocks ? fixture-server) {
    # Only fixture-mac reaches this: the one host with a pinned peer.
    assertion = peerBlocks.fixture-server.data.StrictHostKeyChecking or null == "yes";
    message = "fixture: ssh block for the pinned peer fixture-server must set StrictHostKeyChecking = \"yes\"";
  };
}
