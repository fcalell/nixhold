{ config, lib, ... }:
# Fixture-only service that exercises the caddy tailnet-TLS path:
# declares a single tailnet HTTP endpoint so the caddy infra module
# generates a node-FQDN vhost (with `tls`) plus the tailscale-cert
# oneshot/timer/path units. No real backend daemon is emitted — the
# build only needs the generated config to be valid.
let
  cfg = config.nixhold.services.fixtureweb;
  types' = config.nixhold.types;
in
{
  options.nixhold.services.fixtureweb = {
    enable = lib.mkEnableOption "fixture web service (caddy tailnet-TLS coverage)";
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
      expose.app = {
        network = "tailnet";
        protocol = "https";
        backend = "web";
        pathPrefix = "/app";
        # Exercise the raw-config escape hatch.
        extraConfig = "encode zstd gzip";
      };
    };
  };
}
