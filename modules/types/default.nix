{ lib, ... }:
let
  inherit (lib) mkOption types;

  # Per-service port declarations. Service modules set
  # `nixhold.services.<svc>.network.ports.<name> = <port>`; endpoints
  # in `expose` reference port names symbolically via `backend`.
  networkType = types.submodule {
    options = {
      ports = mkOption {
        type = types.attrsOf types.port;
        default = { };
        example = {
          rocket = 8222;
          websocket = 3012;
        };
        description = ''
          Internal ports the service listens on. Bound to
          127.0.0.1 unless an endpoint in `expose` references
          them. Names are referenced by `expose.<x>.backend`.
        '';
      };
    };
  };

  # Per-endpoint declarations attrset. Each named endpoint binds a
  # backend port to a network + (subdomain | localhost) + path
  # prefix. v1 supports HTTP-family protocols only.
  endpointType = types.submodule {
    options = {
      network = mkOption {
        type = types.str;
        description = ''
          Name of the network this endpoint is reachable on.
          Must be a key in `mkFleet`'s `networks` arg, or
          `"localhost"` (built-in, for 127.0.0.1-bound
          endpoints). Lint rejects unknown values.
        '';
        example = "tailnet";
      };

      protocol = mkOption {
        type = types.enum [
          "https"
          "http"
          "ws"
          "wss"
        ];
        default = "https";
        description = ''
          Endpoint protocol. v1: HTTP-family only. TLS strategy
          is per-network (declared on the network), not
          per-endpoint.
        '';
      };

      subdomain = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Subdomain under the network's domain (internet
          networks) or MagicDNS suffix (tailscale networks).
          Required on non-`localhost` networks; forbidden on
          `localhost`. Lint enforces.
        '';
        example = "vault";
      };

      backend = mkOption {
        type = types.str;
        description = ''
          Name of the port the endpoint resolves to. References
          `nixhold.services.<svc>.network.ports.<this-name>`.
        '';
        example = "rocket";
      };

      pathPrefix = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          If set, this endpoint claims only
          `<subdomain>.<domain>/<prefix>`. Multiple endpoints
          can share a subdomain by carving different prefixes;
          caddy emits a single vhost with multiple location
          blocks. `expose.routes` does not exist — multi-path
          services declare multiple endpoints.
        '';
        example = "/api";
      };

      description = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Free-text description surfaced by `nixhold status`.
          Recommended for `localhost` endpoints (which otherwise
          have no public-facing name to identify them by).
        '';
      };

      extraConfig = mkOption {
        type = types.lines;
        default = "";
        description = ''
          Raw Caddyfile directives injected inside this endpoint's
          handle block, before the framework's default
          `reverse_proxy`. Escape hatch for apps that need more than
          a single reverse_proxy — `encode`, a websocket split
          (`reverse_proxy /ws <port>`), header tweaks. Empty for the
          common case; the data-driven model still generates the
          vhost, FQDN, and (tailnet) TLS.
        '';
        example = "encode zstd gzip";
      };
    };
  };

  exposeType = types.attrsOf endpointType;
in
{
  # `nixhold.types` is a read-only attrset of submodule types.
  # Service modules read it with
  #   let types = config.nixhold.types;
  # and reference `types.expose` / `types.network` inside
  # `mkOption { type = ...; }`.
  #
  # Declared as `internal` so the option doesn't pollute the
  # rendered docs surface — it's framework-facing, not
  # operator-facing.
  options.nixhold.types = mkOption {
    type = types.attrsOf types.raw;
    readOnly = true;
    internal = true;
    default = {
      expose = exposeType;
      network = networkType;
    };
    description = ''
      Shared submodule types for service-module option
      declarations. v1 surface: `expose`, `network`. Additional
      types land alongside the consumer infra module that needs
      them.
    '';
  };
}
