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
          endpoints). An unknown name — or a network missing the
          field its type needs to address the endpoint — is an
          assertion (`modules/infra/endpoints.nix`).
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
          Endpoint protocol. v1: HTTP-family only — all four
          values route through the same vhost (a websocket is an
          upgrade on the same connection), so this is
          documentation of what the backend speaks, not a routing
          switch. TLS strategy is per-network (declared on the
          network), not per-endpoint.
        '';
      };

      subdomain = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Subdomain under the network's domain. Required on
          `internet` networks (the FQDN is
          `<subdomain>.<domain>`); rejected on `tailscale`
          networks, where the FQDN is the node's own MagicDNS name
          — `tailscale cert` issues for that name only, so tailnet
          endpoints share one vhost and differentiate by
          `pathPrefix` — and on `localhost`, which gets no vhost
          at all. Assertions in `modules/infra/endpoints.nix`.
        '';
        example = "vault";
      };

      backend = mkOption {
        type = types.str;
        description = ''
          Name of the port the endpoint resolves to. References
          `nixhold.services.<svc>.network.ports.<this-name>`; a
          name that resolves to no declared port is an assertion
          (`modules/infra/endpoints.nix`) as well as a lint
          violation.
        '';
        example = "rocket";
      };

      pathPrefix = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          If set, this endpoint claims only
          `<fqdn>/<prefix>`. Multiple endpoints can share an FQDN
          by carving different prefixes; caddy emits a single
          vhost with one `handle <prefix>/*` block each, plus a
          redirect from the bare prefix to `<prefix>/`.
          `expose.routes` does not exist — multi-path services
          declare multiple endpoints.

          An absolute path with no trailing slash (`/vault`).
          Because the routing form matches whole path segments,
          `/task` and `/tasks` are disjoint, but two prefixes on
          one FQDN where one is a segment prefix of the other
          (`/tv`, `/tv/x`) are an assertion.
        '';
        example = "/api";
      };

      stripPrefix = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Whether `pathPrefix` is stripped before proxying. `true`
          (default) adds a caddy `uri strip_prefix` inside the
          endpoint's handle block — the backend sees paths relative
          to the prefix. Set `false` for apps that mount themselves
          under the prefix and expect it passed through, e.g.
          vaultwarden with a path in `DOMAIN`. Only meaningful when
          `pathPrefix` is set.
        '';
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

      auth = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Require the network's identity mechanism in front of
          this endpoint. On `tailscale` networks that is the node
          identity behind the connection — caddy `forward_auth` to
          tailscale's nginx-auth daemon, see ARCHITECTURE "Tailnet
          identity auth". `false` is the explicit opt-out: the
          identity headers are stripped instead, so a backend can
          never see a forged one. `internet` networks have no
          identity mechanism yet, so endpoints there must set
          `false` explicitly (assertion) and own their auth at the
          app level.

          This is authentication, not authorization: it proves the
          request comes from a non-tagged node of the expected
          tailnet and tells the backend who, but any such node passes.
          Which devices and users may reach this host is the
          Tailscale ACL's decision; per-user gating beyond that is the
          backend's own business (the identity headers are there for
          it).
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
