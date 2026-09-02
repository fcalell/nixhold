{ config, lib, ... }:
# Fixture-only service that exercises the caddy exposure paths: a
# node-FQDN tailnet vhost (with `tls`) plus the tailscale-cert
# oneshot/timer/path units, and an internet vhost on caddy ACME. Its
# three endpoints cover every auth branch — an authenticated tailnet
# endpoint (`app`, the default), an opted-out tailnet one (`open`),
# and an internet one (`pub`), which has no identity mechanism to ask
# for and must opt out. No real backend daemon is emitted — the build
# only needs the generated config to be valid.
let
  cfg = config.nixhold.services.fixtureweb;
  types' = config.nixhold.types;
in
{
  options.nixhold.services.fixtureweb = {
    enable = lib.mkEnableOption "fixture web service (caddy exposure coverage)";
    network = lib.mkOption {
      type = types'.network;
      default = { };
    };
    expose = lib.mkOption {
      type = types'.expose;
      default = { };
    };
  };

  config = lib.mkIf cfg.enable {
    nixhold.services.fixtureweb = {
      network.ports.web = 8088;
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
        open = {
          network = "tailnet";
          protocol = "https";
          backend = "web";
          pathPrefix = "/open";
          auth = false;
        };
        # Internet endpoints have no identity mechanism yet, so the
        # opt-out is mandatory (assertion in the caddy module).
        pub = {
          network = "public";
          protocol = "https";
          backend = "web";
          subdomain = "app";
          auth = false;
        };
      };
    };
  };
}
