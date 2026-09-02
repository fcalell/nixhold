{ config, lib, ... }:
# Fixture-only service that exercises the caddy exposure paths. It
# declares the backend port only; each fixture host declares the
# endpoints it wants on it (`expose` is an ordinary option), so one
# service can cover the tailnet branches on fixture-server and the
# internet branch on fixture-gateway without either host violating the
# "one listener, one posture" assertion. No real backend daemon is
# emitted — the build only needs the generated config to be valid.
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
    nixhold.services.fixtureweb.network.ports.web = 8088;
  };
}
