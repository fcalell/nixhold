# fixture-guest — the fixture's guest ("Guests"): a server-profile host
# that fixture-desktop names under `guests`, with one render node and
# one sound card granted. Its own eval is what the machine's
# `containers.fixture-guest.path` points at, so building
# fixture-desktop builds this too; the check on this host reads the
# guest side of the boundary, ./desktop-stub.nix the machine side.
{ config, lib, ... }:
let
  me = config.nixhold.fleet.derived.guests.fixture-guest;
in
{
  # The guest carries the same kind of things any server does: an
  # endpoint caddy terminates on the guest's own FQDN with the cert
  # the guest's own tailscaled issues.
  imports = [ ./modules/fixtureweb.nix ];
  nixhold.services.fixtureweb = {
    enable = true;
    expose.app = {
      network = "tailnet";
      protocol = "https";
      backend = "web";
      pathPrefix = "/app";
    };
  };

  assertions = [
    {
      assertion = config.boot.isContainer && config.boot.isNspawnContainer;
      message = "fixture-guest: a guest is not marked as a container";
    }
    {
      # No hardware of its own: no layout, no loader, no swap, no
      # report — and the facter guard does not fire, since the stub
      # sets nothing to opt out of it.
      assertion =
        config.disko.devices.disk == { }
        && !config.boot.loader.systemd-boot.enable
        && !config.zramSwap.enable
        && config.nixhold.hardware.facterReport == null;
      message = "fixture-guest: the hardware module rendered something for a container";
    }
    {
      assertion =
        me.machine == "fixture-desktop"
        &&
          me.devices == [
            "/dev/dri/renderD128"
            "/dev/snd/by-id/usb-Fixture_Card_0001-00"
          ];
      message = "fixture-guest: derived.guests does not carry the machine's entry";
    }
    {
      # The veth's guest end and the route through the machine, from
      # the same derived row the machine reads.
      assertion =
        (lib.head config.networking.interfaces.eth0.ipv4.addresses).address == me.localAddress
        && (lib.head config.networking.interfaces.eth0.ipv4.routes).address == me.hostAddress
        && config.networking.defaultGateway.address == me.hostAddress
        && !config.networking.useDHCP
        && !config.networking.useHostResolvConf
        && config.services.resolved.enable;
      message = "fixture-guest: the guest's network is not the derived veth pair";
    }
    {
      # A full host: its own tailnet node, sshd scoped to it, the
      # fleet key at the path every host decrypts with.
      assertion =
        config.services.tailscale.enable
        && config.services.openssh.enable
        && config.age.identityPaths == [ "/etc/nixhold/fleet.key" ]
        && config.nixhold.infra.url.fixtureweb.app == "https://fixture-guest.fixture.ts.net/app";
      message = "fixture-guest: a guest is not the full host its roster entry declares";
    }
  ];
}
