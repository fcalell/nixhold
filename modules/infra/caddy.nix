# Caddy infrastructure module. Reads the resolved endpoint list
# (`nixhold.infra.endpoints`, derived once in ./endpoints.nix) and
# emits one vhost per FQDN. Endpoints sharing an FQDN (different
# `pathPrefix`) collapse into a single vhost with multiple handle
# blocks.
#
# Addressing depends on network type (see ARCHITECTURE "Tailnet
# TLS"):
#   - tailscale → FQDN is the node's own MagicDNS name
#     (`<host>.<magicDnsSuffix>`); `subdomain` is rejected, services
#     differentiate by pathPrefix; TLS is a `tailscale cert` fetched by
#     a systemd oneshot + weekly timer, reloaded via a path unit.
#   - internet  → FQDN is `<subdomain>.<domain>`; TLS via caddy ACME.
#
# Auth follows the network type (see ARCHITECTURE "Tailnet identity
# auth"): a tailscale endpoint with `auth = true` (the default) gets a
# `forward_auth` to tailscale's nginx-auth daemon, which resolves the
# source address to a tailnet login and copies the identity headers to
# the backend. Every other endpoint — opted out, or on an internet
# network, which has no identity mechanism yet — strips those same
# headers on the way in, so a backend can never see a forged one.
#
# Auto-activates from data — no enable knob, per ARCHITECTURE
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
  tlsDir = "/var/lib/caddy/tls";
  tlsCert = "${tlsDir}/cert.crt";
  tlsKey = "${tlsDir}/cert.key";
  # Staged there, then moved into place, so the path unit below never
  # sees a cert whose matching key has not landed yet.
  tlsStaging = "${tlsDir}/staging";

  # caddy's admin API is what `caddy reload` (nixpkgs' ExecReload,
  # `services.caddy.enableReload`) talks to. On its default
  # localhost:2019 every local uid can POST /load and replace the
  # running config — including stripping the forward_auth gates below.
  # A unix socket in the unit's RuntimeDirectory scopes it to the
  # caddy user; ExecReload runs as that same user and takes the
  # address from the config, so reloads keep working.
  adminSocket = "/run/caddy/admin.sock";

  endpoints = config.nixhold.infra.endpoints;
  grouped = lib.groupBy (e: e.fqdn) endpoints;

  # Tailscale vhosts on this host. v1 assumes a single tailscale
  # network, so there is one node cert covering them all.
  tailscaleFqdns = lib.unique (map (e: e.fqdn) (lib.filter (e: e.netType == "tailscale") endpoints));
  hasTailscale = tailscaleFqdns != [ ];
  hasInternet = lib.any (e: e.netType == "internet") endpoints;
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

  # Two prefixes on one FQDN overlap when one is a path-*segment*
  # prefix of the other (`/tv` and `/tv/x`): the routing form is
  # `handle <prefix>/*`, so `/tv/x` is claimed by both and which one
  # wins is caddy's specificity sort, not the operator's intent.
  # String overlap alone (`/task` vs `/tasks`) is not a conflict —
  # `/task/*` never matches `/tasks/…`.
  overlapping = lib.concatLists (
    lib.mapAttrsToList (
      fqdn: eps:
      let
        prefixed = lib.filter (e: e.pathPrefix != null) eps;
      in
      lib.concatMap (
        a:
        map (b: "${fqdn}: ${a.label} (${a.pathPrefix}) vs ${b.label} (${b.pathPrefix})") (
          lib.filter (
            b:
            a.label != b.label
            && (
              # An identical prefix is a conflict in either direction;
              # list the pair once, by label order.
              if a.pathPrefix == b.pathPrefix then
                a.label < b.label
              else
                lib.hasPrefix "${a.pathPrefix}/" b.pathPrefix
            )
          ) prefixed
        )
      ) prefixed
    ) grouped
  );

  # Internet networks have no identity mechanism, so `auth` there is
  # not a default worth inheriting — it has to be turned off by hand.
  authOnInternet = lib.filter (e: e.auth && e.netType == "internet") endpoints;

  # caddy's listener is not per-interface: one `:443` on every
  # address serves every vhost. Tailnet vhosts are kept tailnet-only
  # by the interface-scoped firewall rule — which stops being scoped
  # the moment an internet endpoint opens 80/443 fleet-wide.
  unauthedTailnet = lib.filter (e: e.netType == "tailscale" && !e.auth) endpoints;

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
  authedEndpoints = lib.filter isAuthed endpoints;

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
      net = config.nixhold.fleet.network.${e.network};
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

  # Body of one endpoint's handle block: the auth gate, the prefix
  # strip, the endpoint's own extraConfig (`encode`, a websocket
  # split, …), then the framework's reverse_proxy.
  #
  # Written in that order for the reader; caddy applies its own
  # directive order inside a handle block, and `uri` sorts ahead of
  # `forward_auth` (verified against the adapted JSON: the `rewrite`
  # handler precedes the forward_auth `reverse_proxy`). That is what
  # `handle_path` did too, so the daemon keeps seeing the same
  # already-stripped `Original-URI` it has always seen — it uses the
  # header for logging only.
  handleBody =
    e:
    lib.concatStringsSep "\n" (
      lib.optional (isAuthed e) (forwardAuth e)
      ++ lib.optional (e.pathPrefix != null && e.stripPrefix) "uri strip_prefix ${e.pathPrefix}"
      ++ lib.optional (lib.removeSuffix "\n" e.extraConfig != "") (lib.removeSuffix "\n" e.extraConfig)
      ++ [ (reverseProxy e) ]
    );

  mkVhostExtraConfig =
    eps:
    let
      isTailscale = (lib.head eps).netType == "tailscale";
      withPrefix = lib.filter (e: e.pathPrefix != null) eps;
      withoutPrefix = lib.filter (e: e.pathPrefix == null) eps;

      # One directive form for every prefixed endpoint: `handle
      # <prefix>/*` claims whole path segments only (`/tvx/y` is not
      # `/tv`'s), and stripping is an explicit `uri strip_prefix`
      # inside rather than the `handle` vs `handle_path` split, whose
      # relative specificity across two directives is undocumented.
      # `/*` does not match the bare prefix, so a top-level redirect
      # sends `/tv` to `/tv/` (query string preserved, and only when
      # there is one) — which is what an app with relative URLs needs
      # anyway.
      redirs = lib.concatMapStrings (e: ''
        redir ${e.pathPrefix} ${e.pathPrefix}/{http.request.uri.prefixed_query}
      '') withPrefix;
      handlePrefixed = lib.concatMapStrings (e: ''
        handle ${e.pathPrefix}/* {
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
    tlsBlock + redirs + handlePrefixed + handleDefault;

  virtualHosts = lib.mapAttrs (_fqdn: eps: { extraConfig = mkVhostExtraConfig eps; }) grouped;
in
{
  imports = [ ./endpoints.nix ];

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
          assertion = overlapping == [ ];
          message = ''
            nixhold caddy: path prefixes on one FQDN overlap
            (${lib.concatStringsSep "; " overlapping}); one is a path-segment
            prefix of the other, so requests under it are claimed by both and
            caddy's specificity sort — not the declaration — decides. Give the
            endpoints disjoint prefixes.
          '';
        }
        {
          assertion = authOnInternet == [ ];
          message = ''
            nixhold caddy: endpoints on an internet network request the
            network's identity mechanism (${lib.concatStringsSep ", " (map (e: e.label) authOnInternet)}),
            but internet networks have no identity mechanism yet. Set
            `auth = false` explicitly — app-level auth is the endpoint's own
            business until an internet mechanism lands.
          '';
        }
        {
          assertion = !(hasInternet && unauthedTailnet != [ ]);
          message = ''
            nixhold caddy: this host serves internet endpoints and tailnet
            endpoints that opted out of auth
            (${lib.concatStringsSep ", " (map (e: e.label) unauthedTailnet)}).
            caddy's listener is not per-interface — one `:443` on every
            address serves every vhost — and what keeps a tailnet vhost
            tailnet-only is the firewall rule scoped to the tailscale
            interface. An internet endpoint opens 80/443 on every interface,
            so those tailnet vhosts (and the tailnet FQDN's HTTP→HTTPS
            redirect) become reachable from the LAN and the internet by
            anyone who can resolve the name, with nothing in front of them.
            Keep `auth = true` (the default) on the tailnet endpoints, or
            move the internet endpoint to a host that serves no tailnet vhost.
          '';
        }
        {
          assertion = authedEndpoints == [ ] || (config.nixhold.services.tailscale.enable or false);
          message = ''
            nixhold caddy: authenticated tailnet endpoints
            (${lib.concatStringsSep ", " (map (e: e.label) authedEndpoints)}) need
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

    (lib.mkIf (endpoints != [ ]) {
      services.caddy = {
        enable = true;
        inherit virtualHosts;
        # Owner-only socket (the `|<mode>` suffix caddy's address
        # parser takes), in a RuntimeDirectory owned by the caddy
        # user — so nothing but caddy itself can drive /load.
        globalConfig = "admin unix/${adminSocket}|0600";
      };

      systemd.services.caddy.serviceConfig = {
        RuntimeDirectory = "caddy";
        RuntimeDirectoryMode = "0750";
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
        # config load and nixpkgs' RestartPreventExitStatus=1 keeps it
        # down. Once the cert lands, the path unit below does a
        # reload-or-restart, which is what brings caddy up.
        before = [ "caddy.service" ];
        wantedBy = [ "caddy.service" ];
        path = [
          pkgs.tailscale
          pkgs.coreutils
        ];
        serviceConfig = {
          Type = "oneshot";
          # A first boot runs this before the node has joined the
          # tailnet, and `tailscale cert` fails. Without a retry the
          # next attempt is the timer's — a week away once the 2min
          # OnBootSec run has been spent. (Restart= on Type=oneshot is
          # allowed for on-failure; systemd here is 260.)
          Restart = "on-failure";
          RestartSec = "30s";
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
            # Staged, not written straight into the live paths: cert
            # and key are two separate writes, and the path unit
            # watches the live key — so a reload can only fire once
            # both halves are in place.
            install -d -m 0700 -o root -g root ${tlsStaging}
            rm -f ${tlsStaging}/cert.crt ${tlsStaging}/cert.key
            tailscale cert \
              --cert-file=${tlsStaging}/cert.crt \
              --key-file=${tlsStaging}/cert.key \
              ${tailscaleFqdn}
            chown caddy:caddy ${tlsStaging}/cert.crt ${tlsStaging}/cert.key
            chmod 0640 ${tlsStaging}/cert.crt
            chmod 0600 ${tlsStaging}/cert.key
            # Key last: it is the watched path, so the reload it
            # triggers always finds the matching cert already there.
            mv -f ${tlsStaging}/cert.crt ${tlsCert}
            mv -f ${tlsStaging}/cert.key ${tlsKey}
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
          # The key is the half moved into place last (PathChanged
          # covers the rename), so this fires on a complete pair.
          PathChanged = tlsKey;
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
