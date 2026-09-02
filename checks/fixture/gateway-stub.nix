# fixture-gateway — the fixture's internet-facing host. It exists so
# the internet branch of caddy/firewall (ACME vhost under
# `<subdomain>.<domain>`, 80/443 opened fleet-wide, no tailnet cert
# units) is exercised on a host of its own: caddy's listener is not
# per-interface, so a host that serves an internet endpoint must not
# also serve unauthenticated tailnet ones, and the framework asserts
# exactly that.
{ ... }:
{
  imports = [
    ./hardware-stub.nix
    ./modules/fixtureweb.nix
  ];

  # On the tailnet for operator ssh, but serving nothing there: this
  # is also the "member of a tailscale network with no tailnet
  # endpoint" branch — no tailnet vhost, no `tailscale cert` units, no
  # interface-scoped firewall opening.
  nixhold.services.fixtureweb = {
    enable = true;
    # Internet endpoints have no identity mechanism yet, so the
    # opt-out is mandatory (assertion in the caddy module).
    expose.pub = {
      network = "public";
      protocol = "https";
      backend = "web";
      subdomain = "app";
      auth = false;
    };
  };
}
