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
# Auto-activates from data — no enable knob, per ROADMAP
# "infra activation: auto from declared data". A host with zero
# HTTP endpoints does not start caddy.
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
      _svcName: svc:
      lib.mapAttrsToList (
        epName: ep:
        ep
        // {
          _epName = epName;
          backendPort = svc.network.ports.${ep.backend} or null;
        }
      ) (svc.expose or { })
    ) (config.nixhold.services or { })
  );

  httpEndpoints = lib.filter (
    e:
    (e.protocol == "https" || e.protocol == "http")
    && e.network != "localhost"
    && e.backendPort != null
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

  mkVhostExtraConfig =
    eps:
    let
      isTailscale = (lib.head eps).netType == "tailscale";
      withPrefix = lib.filter (e: e.pathPrefix != null) eps;
      withoutPrefix = lib.filter (e: e.pathPrefix == null) eps;
      # Per-endpoint extraConfig is injected inside the handle block,
      # before the default reverse_proxy — apps add `encode`, a
      # websocket split, etc. without leaving the data-driven model.
      # `handle_path` strips the prefix before proxying; endpoints
      # that mount themselves under the prefix (stripPrefix = false)
      # get a non-stripping `handle` instead.
      handlePrefixed = lib.concatMapStrings (e: ''
        ${if e.stripPrefix then "handle_path" else "handle"} ${e.pathPrefix}* {
          ${e.extraConfig}
          reverse_proxy http://127.0.0.1:${toString e.backendPort}
        }
      '') withPrefix;
      handleDefault = lib.optionalString (withoutPrefix != [ ]) (
        let
          e = lib.head withoutPrefix;
        in
        ''
          handle {
            ${e.extraConfig}
            reverse_proxy http://127.0.0.1:${toString e.backendPort}
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
      ];
    }

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
