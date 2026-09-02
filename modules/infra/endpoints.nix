# Endpoint resolution — the single place `nixhold.services.*.expose`
# is turned into resolved, addressable endpoints. `caddy.nix` and
# `firewall.nix` both import this module (imports are idempotent, and
# the server profile attaches the two infra modules individually) and
# read `config.nixhold.infra.endpoints`. Deriving the list twice is
# exactly how the two drifted: the firewall opened 80/443 for
# endpoints caddy silently refused to serve.
#
# Nothing here drops an endpoint quietly. Every reason resolution can
# fail — an unknown network name, a network missing the field its type
# needs, a `backend` that names no declared port, a `subdomain` the
# addressing model has no place for — is an assertion. An endpoint the
# operator declared and nothing serves is a misconfiguration, not a
# default. (Eval still has to produce a value while the assertion is
# being reported, so unresolvable endpoints are filtered out of the
# list itself; the assertion is what fails the build.)
#
# `protocol`'s v1 enum (`http`/`https`/`ws`/`wss`) is entirely
# HTTP-family — websockets are an upgrade on the same connection and
# ride the same vhost — so protocol takes no part in the filtering.
# When a non-HTTP protocol lands it arrives with the infra module that
# terminates it, and this list gains a branch rather than a silent
# omission.
{ config, lib, ... }:
let
  inherit (lib) mkOption types;

  hostName = config.networking.hostName;
  fleetNetworks = config.nixhold.fleet.network;
  services = config.nixhold.services or { };

  # Every declared endpoint, annotated with where it came from and the
  # port its `backend` resolves to (`null` when it resolves to none).
  declared = lib.flatten (
    lib.mapAttrsToList (
      svcName: svc:
      lib.mapAttrsToList (
        epName: ep:
        ep
        // {
          service = svcName;
          endpoint = epName;
          label = "${svcName}.${epName}";
          backendPort = svc.network.ports.${ep.backend} or null;
          backendPorts = lib.attrNames (svc.network.ports or { });
        }
      ) (svc.expose or { })
    ) services
  );

  # `localhost` is the built-in network: 127.0.0.1-bound, no vhost, no
  # firewall opening. Everything else is routed by the infra modules.
  isLocalhost = e: e.network == "localhost";
  routed = lib.filter (e: !isLocalhost e) declared;

  netOf = e: fleetNetworks.${e.network} or null;

  # The field each network type needs before an FQDN can be computed.
  netFieldFor = t: if t == "tailscale" then "magicDnsSuffix" else "domain";
  netComplete =
    e:
    let
      n = netOf e;
    in
    if n.type == "tailscale" then n.magicDnsSuffix != null else n.domain != null;

  # Tailscale: the node's own MagicDNS name — `tailscale cert` only
  # issues for the node FQDN, so every tailnet service on a host shares
  # one vhost and routes by pathPrefix, and `subdomain` has no meaning.
  # Internet: `<subdomain>.<domain>`.
  fqdnOf =
    e:
    let
      n = netOf e;
    in
    if n.type == "tailscale" then "${hostName}.${n.magicDnsSuffix}" else "${e.subdomain}.${n.domain}";

  subdomainRequired = e: (netOf e).type == "internet";

  resolvable =
    e:
    netOf e != null
    && netComplete e
    && e.backendPort != null
    && (subdomainRequired e -> e.subdomain != null);

  resolved = map (
    e:
    e
    // {
      netType = (netOf e).type;
      fqdn = fqdnOf e;
    }
  ) (lib.filter resolvable routed);

  # --- violations -------------------------------------------------
  labels = eps: lib.concatStringsSep ", " (map (e: e.label) eps);

  unknownNetwork = lib.filter (e: netOf e == null) routed;
  knownNetwork = lib.filter (e: netOf e != null) routed;

  incompleteNetwork = lib.filter (e: !netComplete e) knownNetwork;
  unknownBackend = lib.filter (e: e.backendPort == null) declared;

  subdomainOnLocalhost = lib.filter (e: e.subdomain != null) (lib.filter isLocalhost declared);
  subdomainOnTailscale = lib.filter (
    e: (netOf e).type == "tailscale" && e.subdomain != null
  ) knownNetwork;
  subdomainMissing = lib.filter (e: subdomainRequired e && e.subdomain == null) knownNetwork;

  # The routing forms are built by string concatenation onto the
  # prefix (`handle <prefix>/*`, `uri strip_prefix <prefix>`, a
  # trailing-slash redirect); a prefix that is not a bare, absolute,
  # non-trailing-slash path silently produces a route nobody can hit.
  badPathPrefix = lib.filter (
    e:
    e.pathPrefix != null
    && (!lib.hasPrefix "/" e.pathPrefix || e.pathPrefix == "/" || lib.hasSuffix "/" e.pathPrefix)
  ) declared;

  declaredNetworks = lib.concatStringsSep ", " (lib.attrNames fleetNetworks ++ [ "localhost" ]);
in
{
  options.nixhold.infra.endpoints = mkOption {
    type = types.listOf types.raw;
    readOnly = true;
    internal = true;
    default = resolved;
    description = ''
      Resolved routable endpoints on this host: every
      `nixhold.services.<svc>.expose.<ep>` that is not on the
      built-in `localhost` network, annotated with `service`,
      `endpoint`, `label`, `backendPort`, `netType` and the `fqdn`
      it is reachable at. The infra modules consume this instead of
      re-walking `nixhold.services` — caddy emits one vhost per
      distinct `fqdn`, the firewall opens the HTTP ports for exactly
      the endpoints caddy serves.

      Framework-facing (`internal`): service modules declare
      endpoints, they do not read them back.
    '';
  };

  config.assertions = [
    {
      assertion = unknownNetwork == [ ];
      message = ''
        nixhold expose: unknown network on ${labels unknownNetwork} — this fleet
        declares no network named ${
          lib.concatStringsSep ", " (lib.unique (map (e: "\"${e.network}\"") unknownNetwork))
        }.
        `network` must be a key in mkFleet's `networks` argument, or the
        built-in "localhost". Declared here: ${declaredNetworks}.
      '';
    }
    {
      assertion = incompleteNetwork == [ ];
      message = ''
        nixhold expose: unaddressable network on ${labels incompleteNetwork} — ${
          lib.concatStringsSep ", " (
            lib.unique (
              map (
                e: "network \"${e.network}\" (type ${(netOf e).type}) has no ${netFieldFor (netOf e).type}"
              ) incompleteNetwork
            )
          )
        }.
        Set that field on the network in mkFleet's `networks` argument;
        without it no FQDN exists to serve the endpoint at.
      '';
    }
    {
      assertion = unknownBackend == [ ];
      message = ''
        nixhold expose: unknown backend port on ${labels unknownBackend} — ${
          lib.concatStringsSep ", " (
            map (
              e:
              "${e.label} wants \"${e.backend}\", ${e.service} declares ${
                if e.backendPorts == [ ] then "no ports" else lib.concatStringsSep "/" e.backendPorts
              }"
            ) unknownBackend
          )
        }.
        `backend` names a key of `nixhold.services.<svc>.network.ports`.
      '';
    }
    {
      assertion = subdomainOnLocalhost == [ ];
      message = ''
        nixhold expose: `subdomain` set on the built-in "localhost" network by
        ${labels subdomainOnLocalhost}. Localhost endpoints are bound to
        127.0.0.1 and get no vhost, so there is no name to put a subdomain
        under. Drop `subdomain`, or move the endpoint to a real network.
      '';
    }
    {
      assertion = subdomainOnTailscale == [ ];
      message = ''
        nixhold expose: `subdomain` set on a tailscale network by
        ${labels subdomainOnTailscale}. A tailnet endpoint is addressed at the node's own
        MagicDNS name — `tailscale cert` issues for that name only — so all
        tailnet endpoints on a host share one vhost and differentiate by
        `pathPrefix`. Drop `subdomain` and give the endpoint a `pathPrefix`.
      '';
    }
    {
      assertion = subdomainMissing == [ ];
      message = ''
        nixhold expose: no `subdomain` on the internet endpoints
        ${labels subdomainMissing}. The FQDN is `<subdomain>.<domain>`; without a
        subdomain the endpoint would claim the network's root domain, which
        the framework does not hand out implicitly. Set `subdomain`.
      '';
    }
    {
      assertion = badPathPrefix == [ ];
      message = ''
        nixhold expose: malformed `pathPrefix` on ${labels badPathPrefix} (${
          lib.concatStringsSep ", " (map (e: "${e.label} = \"${e.pathPrefix}\"") badPathPrefix)
        }).
        A prefix is an absolute path with no trailing slash, e.g. "/vault" —
        the routing form appends to it (`handle <prefix>/*`).
      '';
    }
  ];
}
