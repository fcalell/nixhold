# fixture-server — the fixture's tailnet-only host. Declares what the
# framework's baseline + chosen profile cannot fill in on its own
# (hardware-shaped bits, via ./hardware-stub.nix) and exercises the
# caddy tailnet path: a node-FQDN vhost with the tailscale-issued
# cert, both auth branches (the default forward_auth and an explicit
# opt-out), prefix routing with and without stripping, and the
# tailscale-cert oneshot/timer/path units.
#
# The internet branch lives on fixture-gateway: caddy asserts that no
# single host mixes internet endpoints with unauthenticated tailnet
# ones, since one listener serves both.
{ ... }:
{
  imports = [
    ./hardware-stub.nix
    ./modules/fixtureweb.nix
    ./known-hosts-assertions.nix
  ];

  nixhold.services.fixtureweb = {
    enable = true;
    expose = {
      # Authenticated by default: forward_auth + copy_headers.
      app = {
        network = "tailnet";
        protocol = "https";
        backend = "web";
        pathPrefix = "/app";
        # Exercise the raw-config escape hatch.
        extraConfig = "encode zstd gzip";
      };
      # Explicit opt-out on a tailnet: identity headers stripped.
      # Also the non-stripping prefix form (caddy `handle` with no
      # `uri strip_prefix`), which is what vaultwarden needs.
      open = {
        network = "tailnet";
        protocol = "https";
        backend = "web";
        pathPrefix = "/open";
        stripPrefix = false;
        auth = false;
      };
    };
  };

  # Exercise the operator-key path end-to-end: owner defaults to
  # "user", homePath defaults to ".ssh/personal", the HM module emits
  # the symlink + `.pub` activation, and the committed
  # keys/hosts/fixture-server/identity.pub (derived from this
  # throwaway key) defaults `fleet.hosts.fixture-server.loginPubkey`.
  nixhold.secrets.personal = {
    sshIdentity = true;
    description = "Throwaway fixture SSH key (checked-in, not a real secret)";
  };
}
