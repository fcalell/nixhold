# The guest side of "Guests": what a host's own eval sets when a
# machine's roster entry names it under `guests`. NixOS-only.
#
# A guest is a full host — its own tailnet node, sshd pin, caddy and
# secrets — so its module list is the one every host gets, and the
# same list is what the machine's `containers.<guest>` evaluates. What
# is here is only what running as a NixOS container implies, read
# from `nixhold.fleet.derived.guests.<self>` (the machine's entry,
# resolved once in modules/fleet/derived.nix): the container mark
# that makes the NixOS baseline skip the loader and the root
# filesystem and the hardware module skip disko, zram and the facter
# report; the veth's guest end and the route through the machine; and
# a resolver of its own, since the machine's /etc/resolv.conf — a
# stub on 127.0.0.53 on a NetworkManager seat — names nothing
# reachable from another network namespace. systemd-resolved answers
# from its built-in fallback list until tailscaled, which drives
# resolved, hands it MagicDNS and the tailnet's own servers on join.
#
# The address is what nixpkgs' container module injects when it
# evaluates the same list for the machine (the veth's /32 on eth0,
# at normal priority — so this mkDefault yields to it there and the
# two evals agree); the on-link route to the machine and the default
# route through it are declared so networkd, which the server
# profile runs, keeps them when it takes eth0 over.
#
# The store is the machine's: a guest reaches it through the machine's
# nix-daemon socket, so a gc or optimise timer inside the guest would
# run against the machine's store from the wrong side. Both are off
# here at normal priority, over the profiles' mkDefault and over
# nixpkgs' container-config.nix, which defaults `nix.optimise` and
# `networking.useHostResolvConf` at the same mkDefault the profile
# uses; a fleet that wants either back says so with mkForce.
{ config, lib, ... }:
let
  fleet = config.nixhold.fleet;
  me = if fleet.selfName == null then null else fleet.derived.guests.${fleet.selfName} or null;
in
{
  config = lib.mkIf (me != null) {
    boot.isNspawnContainer = true;

    networking = {
      useDHCP = false;
      useHostResolvConf = false;
      interfaces.eth0.ipv4 = {
        addresses = lib.mkDefault [
          {
            address = me.localAddress;
            prefixLength = 32;
          }
        ];
        routes = [
          {
            address = me.hostAddress;
            prefixLength = 32;
          }
        ];
      };
      defaultGateway = lib.mkDefault {
        address = me.hostAddress;
        interface = "eth0";
      };
    };
    services.resolved.enable = lib.mkDefault true;

    nix.gc.automatic = false;
    nix.optimise.automatic = false;
  };
}
