# Caddy infrastructure module. Walks `config.nixhold.services.*`,
# collects HTTP-family endpoints, and emits one vhost per resolved
# FQDN. Endpoints sharing an FQDN (different `pathPrefix`) collapse
# into a single vhost with multiple handle blocks.
#
# Addressing depends on network type (see ROADMAP "Tailnet TLS
# provisioning"):
#   - tailscale → FQDN is the node's own MagicDNS name
#     (`<host>.<magicDnsSuffix>`); `subdomain` is ignored, services
#     differentiate by pathPrefix; TLS is a `tailscale cert` fetched by
#     a systemd oneshot + weekly timer, reloaded via a path unit.
#   - internet  → FQDN is `<subdomain>.<domain>`; TLS via caddy ACME.
#
# Auth follows the network type (see ROADMAP "Tailnet identity
# auth"): a tailscale endpoint with `auth = true` (the default) gets a
# `forward_auth` to tailscale's nginx-auth daemon, which resolves the
# source address to a tailnet login and copies the identity headers to
# the backend. Every other endpoint — opted out, or on an internet
# network, which has no identity mechanism yet — strips those same
# headers on the way in, so a backend can never see a forged one.
#
# Auto-activates from data — no enable knob, per ROADMAP
# "infra activation: auto from declared data". A host with zero
# HTTP endpoints does not start caddy; the auth daemon likewise
# activates only when an authenticated endpoint exists.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  hostName = config.networking.hostName;
  fleetNetworks = config.nixhold.fleet.network;

  tlsDir = "/var/lib/caddy/tls";
  tlsCert = "${tlsDir}/cert.crt";
  tlsKey = "${tlsDir}/cert.key";

  # Walk every service, every expose entry, annotate with the backend
  # port resolved against its parent service's `network.ports`.
  # Endpoints whose backend doesn't resolve get `backendPort = null`
  # and are filtered out below.
  endpoints = lib.flatten (
    lib.mapAttrsToList (
      svcName: svc:
      lib.mapAttrsToList (
        epName: ep:
        ep
        // {
          _epName = epName;
          _label = "${svcName}.${epName}";
          backendPort = svc.network.ports.${ep.backend} or null;
        }
      ) (svc.expose or { })
    ) (config.nixhold.services or { })
  );

  httpEndpoints = lib.filter (
    e:
    (e.protocol == "https" || e.protocol == "http") && e.network != "localhost" && e.backendPort != null
  ) endpoints;

  netTypeOf = e: (fleetNetworks.${e.network} or { }).type or null;

  vhostFqdn =
    e:
    let
      net = fleetNetworks.${e.network} or null;
    in
    if net == null then
      null
    # Tailscale: the node's own MagicDNS name. `subdomain` is dropped —
    # tailscale cert only issues for the node FQDN, so all tailnet
    # services on a host share one vhost and route by pathPrefix.
    else if net.type == "tailscale" && net.magicDnsSuffix != null then
      "${hostName}.${net.magicDnsSuffix}"
    else if net.type == "internet" && net.domain != null then
      "${if e.subdomain != null then "${e.subdomain}." else ""}${net.domain}"
    else
      null;

  endpointsWithFqdn = lib.filter (e: e.fqdn != null) (
    map (
      e:
      e
      // {
        fqdn = vhostFqdn e;
        netType = netTypeOf e;
      }
    ) httpEndpoints
  );

  grouped = lib.groupBy (e: e.fqdn) endpointsWithFqdn;

  # Tailscale vhosts on this host. v1 assumes a single tailscale
  # network, so there is one node cert covering them all.
  tailscaleFqdns = lib.unique (
    map (e: e.fqdn) (lib.filter (e: e.netType == "tailscale") endpointsWithFqdn)
  );
  hasTailscale = tailscaleFqdns != [ ];
  hasInternet = lib.any (e: e.netType == "internet") endpointsWithFqdn;
  tailscaleFqdn = lib.head (tailscaleFqdns ++ [ null ]);

  # Misconfigurations the grouping would otherwise swallow: two
  # endpoints with no pathPrefix on one FQDN (only one could win),
  # or one FQDN spanning network types (TLS strategy is per-vhost).
  ambiguousFqdns = lib.attrNames (
    lib.filterAttrs (_: eps: lib.length (lib.filter (e: e.pathPrefix == null) eps) > 1) grouped
  );
  mixedNetFqdns = lib.attrNames (
    lib.filterAttrs (_: eps: lib.length (lib.unique (map (e: e.netType) eps)) > 1) grouped
  );
  # Internet networks have no identity mechanism, so `auth` there is
  # not a default worth inheriting — it has to be turned off by hand.
  authOnInternet = map (e: e._label) (lib.filter (e: e.auth && netTypeOf e == "internet") endpoints);

  # Identity headers tailscale's nginx-auth daemon produces. One list,
  # two uses: copied in on authenticated endpoints, stripped on every
  # other one so a client can never forge them.
  identityHeaders = [
    "Tailscale-User"
    "Tailscale-Login"
    "Tailscale-Name"
    "Tailscale-Tailnet"
    "Tailscale-Profile-Picture"
  ];

  authSocket = config.services.tailscaleAuth.socketPath;

  # A tailnet connection is already authenticated at the transport
  # layer; the daemon turns that into an HTTP identity. Nothing else
  # can be authenticated in v1 (internet networks have no mechanism).
  isAuthed = e: e.auth && e.netType == "tailscale";
  authedEndpoints = lib.filter isAuthed endpointsWithFqdn;

  indentBy =
    n: s:
    let
      pad = lib.concatStrings (lib.genList (_: " ") n);
    in
    lib.concatStringsSep "\n" (
      map (line: if line == "" then "" else pad + line) (lib.splitString "\n" s)
    );

  # forward_auth to the nginx-auth unix socket. `Expected-Tailnet`
  # makes the daemon reject nodes of a foreign tailnet (403) rather
  # than trusting whatever whois returns.
  forwardAuth =
    e:
    let
      net = fleetNetworks.${e.network};
    in
    ''
      forward_auth unix/${authSocket} {
        uri /auth
        header_up Remote-Addr {remote_host}
        header_up Remote-Port {remote_port}
        header_up Original-URI {uri}
        header_up Expected-Tailnet ${net.magicDnsSuffix}
        copy_headers ${lib.concatStringsSep " " identityHeaders}
      }'';

  reverseProxy =
    e:
    let
      upstream = "http://127.0.0.1:${toString e.backendPort}";
    in
    if isAuthed e then
      "reverse_proxy ${upstream}"
    else
      ''
        reverse_proxy ${upstream} {
        ${indentBy 2 (lib.concatMapStringsSep "\n" (h: "header_up -${h}") identityHeaders)}
        }'';

  # Body of one endpoint's handle block: the auth gate first, then the
  # endpoint's own extraConfig (`encode`, a websocket split, …), then
  # the framework's reverse_proxy.
  handleBody =
    e:
    lib.concatStringsSep "\n" (
      lib.optional (isAuthed e) (forwardAuth e)
      ++ lib.optional (lib.removeSuffix "\n" e.extraConfig != "") (lib.removeSuffix "\n" e.extraConfig)
      ++ [ (reverseProxy e) ]
    );

  mkVhostExtraConfig =
    eps:
    let
      isTailscale = (lib.head eps).netType == "tailscale";
      withPrefix = lib.filter (e: e.pathPrefix != null) eps;
      withoutPrefix = lib.filter (e: e.pathPrefix == null) eps;
      # `handle_path` strips the prefix before proxying; endpoints
      # that mount themselves under the prefix (stripPrefix = false)
      # get a non-stripping `handle` instead.
      handlePrefixed = lib.concatMapStrings (e: ''
        ${if e.stripPrefix then "handle_path" else "handle"} ${e.pathPrefix}* {
        ${indentBy 2 (handleBody e)}
        }
      '') withPrefix;
      handleDefault = lib.optionalString (withoutPrefix != [ ]) (
        let
          e = lib.head withoutPrefix;
        in
        ''
          handle {
          ${indentBy 2 (handleBody e)}
          }
        ''
      );
      # Tailnet vhosts use the tailscale-issued cert; internet vhosts
      # fall through to caddy's ACME.
      tlsBlock = lib.optionalString isTailscale ''
        tls ${tlsCert} ${tlsKey}
      '';
    in
    tlsBlock + handlePrefixed + handleDefault;

  virtualHosts = lib.mapAttrs (_fqdn: eps: { extraConfig = mkVhostExtraConfig eps; }) grouped;
in
{
  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = ambiguousFqdns == [ ];
          message = ''
            nixhold caddy: multiple endpoints without a pathPrefix claim the
            same FQDN (${lib.concatStringsSep ", " ambiguousFqdns}); only one
            default handle per vhost is possible. Give each endpoint a
            distinct pathPrefix or subdomain.
          '';
        }
        {
          assertion = mixedNetFqdns == [ ];
          message = ''
            nixhold caddy: endpoints on different network types resolve to the
            same FQDN (${lib.concatStringsSep ", " mixedNetFqdns}); the TLS
            strategy is per-vhost, so this cannot be routed.
          '';
        }
        {
          assertion = authOnInternet == [ ];
          message = ''
            nixhold caddy: endpoints on an internet network request the
            network's identity mechanism (${lib.concatStringsSep ", " authOnInternet}),
            but internet networks have no identity mechanism yet. Set
            `auth = false` explicitly — app-level auth is the endpoint's own
            business until an internet mechanism lands.
          '';
        }
        {
          assertion = authedEndpoints == [ ] || (config.nixhold.services.tailscale.enable or false);
          message = ''
            nixhold caddy: authenticated tailnet endpoints
            (${lib.concatStringsSep ", " (map (e: e._label) authedEndpoints)}) need
            tailscale's nginx-auth daemon, and the nixpkgs `services.tailscaleAuth`
            module would force-enable tailscaled behind the framework's back.
            Enable `nixhold.services.tailscale` on this host (or opt the
            endpoints out with `auth = false`).
          '';
        }
      ];
    }

    # Tailnet identity auth: the nginx-auth daemon resolves a tailnet
    # source address to a login. Activates from data like caddy itself
    # — only when the host serves an authenticated endpoint.
    (lib.mkIf (authedEndpoints != [ ]) {
      services.tailscaleAuth.enable = true;

      # caddy dials the daemon's unix socket, whose mode is 0660.
      users.users.caddy.extraGroups = [ config.services.tailscaleAuth.group ];

      # Every authenticated vhost forwards to that socket, so it has to
      # exist before caddy takes requests.
      systemd.services.caddy = {
        after = [ "tailscale-nginx-auth.socket" ];
        wants = [ "tailscale-nginx-auth.socket" ];
      };
    })

    (lib.mkIf (endpointsWithFqdn != [ ]) {
      services.caddy = {
        enable = true;
        inherit virtualHosts;
      };
    })

    # Tailnet TLS: fetch/renew the node's `tailscale cert` and reload
    # caddy when it changes. Only when the host serves a tailnet vhost.
    (lib.mkIf hasTailscale {
      # Tailnet-internal — no :80 listener, so disable the HTTP→HTTPS
      # redirect caddy would otherwise add. `auto_https` is global, so
      # only when no internet vhost shares this caddy (those want the
      # redirect).
      services.caddy.globalConfig = lib.mkIf (!hasInternet) "auto_https disable_redirects";

      systemd.tmpfiles.rules = [ "d ${tlsDir} 0750 caddy caddy - -" ];

      systemd.services.tailscale-caddy-cert = {
        description = "Fetch/renew tailscale-issued TLS cert for caddy";
        after = [
          "tailscaled.service"
          "network-online.target"
        ];
        wants = [
          "tailscaled.service"
          "network-online.target"
        ];
        # The vhost hard-references the cert files, so caddy must not
        # start before the first fetch has run — otherwise it exits on
        # config load and Restart=on-abnormal never revives it.
        before = [ "caddy.service" ];
        wantedBy = [ "caddy.service" ];
        path = [
          pkgs.tailscale
          pkgs.coreutils
        ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = pkgs.writeShellScript "tailscale-caddy-cert" ''
            set -euo pipefail
            # Wait for tailscaled — avoids racing first-boot before auth.
            for _ in $(seq 1 30); do
              if tailscale status --self=true --peers=false >/dev/null 2>&1; then
                break
              fi
              sleep 2
            done

            install -d -m 0750 -o caddy -g caddy ${tlsDir}
            tailscale cert \
              --cert-file=${tlsCert} \
              --key-file=${tlsKey} \
              ${tailscaleFqdn}
            chown caddy:caddy ${tlsCert} ${tlsKey}
            chmod 0640 ${tlsCert}
            chmod 0600 ${tlsKey}
          '';
        };
      };

      systemd.timers.tailscale-caddy-cert = {
        description = "Weekly renewal of tailscale-issued TLS cert";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "2min";
          OnCalendar = "weekly";
          Persistent = true;
        };
      };

      systemd.paths.caddy-tls-watch = {
        description = "Watch tailscale-issued cert and reload caddy on change";
        wantedBy = [ "multi-user.target" ];
        pathConfig = {
          PathChanged = tlsCert;
          Unit = "caddy-tls-reload.service";
        };
      };

      systemd.services.caddy-tls-reload = {
        description = "Reload caddy after TLS cert refresh";
        serviceConfig = {
          Type = "oneshot";
          # reload-or-restart (not plain reload): also brings caddy up
          # if it failed an earlier start because the cert was missing.
          ExecStart = "${pkgs.systemd}/bin/systemctl reload-or-restart caddy.service";
        };
      };
    })
  ];
}
