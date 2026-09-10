# fixture-server — the fixture's tailnet-SERVING host. It is a member
# of both networks (`tailnet` and `public`) but exposes endpoints on
# the tailnet only. Its hardware is roster data (`disk` in
# ./default.nix renders the shipped layout), so nothing hardware-shaped
# is declared here; it exercises the caddy tailnet path: a node-FQDN
# vhost with the tailscale-issued cert, both auth branches (the default
# forward_auth and an explicit opt-out), prefix routing with and
# without stripping, and the tailscale-cert oneshot/timer/path units.
#
# The internet branch lives on fixture-gateway: caddy asserts that no
# single host mixes internet endpoints with unauthenticated tailnet
# ones, since one listener serves both. The tailnet-ONLY posture —
# membership of no internet network at all, which is what the sshd
# firewall scoping keys off — lives on fixture-node.
#
# It is also where the shipped HTTP services are built: vaultwarden,
# taskchampion, syncthing and navidrome are imported and enabled
# below, so the check covers each one's endpoint declaration, its
# backup wiring, — for vaultwarden — the `nixhold.infra.url` read-back
# its DOMAIN depends on, and — for navidrome — the socket backend its
# tailnet identity rests on. `syncthing`'s GUI password is
# `required`, so its ciphertext is committed under
# ./secrets/fixture-server/ like every other fixture secret: a
# throwaway nothing decrypts.
{
  config,
  lib,
  inputs,
  ...
}:
{
  imports = [
    ./modules/fixtureweb.nix
    ./known-hosts-assertions.nix
    ./repositories.nix
    # The forker idiom, which is what the fixture stands in for: a
    # host imports the implementations of the services it enables.
    inputs.nixhold.modules.services.nixos.vaultwarden
    inputs.nixhold.modules.services.nixos.taskchampion
    inputs.nixhold.modules.services.nixos.syncthing
    inputs.nixhold.modules.services.nixos.navidrome
  ];

  # No machine ever ran `host install` for a fixture host, so there is
  # no report to point at: opt out of the facter guard.
  nixhold.hardware.facterReport = null;

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
      # The socket-backend form: caddy dials `unix/<path>` in place
      # of a loopback port.
      sock = {
        network = "tailnet";
        protocol = "https";
        backend = "ipc";
        pathPrefix = "/sock";
      };
    };
  };

  # The shipped HTTP services. Each declares its own endpoint whole
  # except for the network, which is fleet data — the one field a host
  # names. `backupDir` puts the nightly copies under a shared root the
  # `backups` group carries off the box.
  nixhold.services = {
    vaultwarden = {
      enable = true;
      expose.web.network = "tailnet";
      backupDir = "/var/lib/backups/vaultwarden";
    };
    taskchampion = {
      enable = true;
      expose.sync.network = "tailnet";
      backupDir = "/var/lib/backups/taskchampion";
    };
    syncthing = {
      enable = true;
      expose.gui.network = "tailnet";
    };
    navidrome = {
      enable = true;
      expose.web.network = "tailnet";
      musicDir = "/srv/music";
      backupDir = "/var/lib/backups/navidrome";
    };
  };

  # The `unit` path, NixOS-only: the secret is the fixtureweb unit's
  # EnvironmentFile, so it defaults to root/0400 and never reaches
  # $HOME. Its ciphertext is committed (fixture-gateway runs the same
  # service without one — the inactive branch).
  assertions =
    let
      s = config.nixhold.secrets.fixtureweb;
    in
    [
      {
        assertion = s.resolvedOwner == "root" && s.resolvedMode == "0400" && s.category == "service";
        message = "fixture: a `unit` secret defaults to root/0400 and category service";
      }
      {
        assertion =
          config.systemd.services.fixtureweb.serviceConfig.EnvironmentFile
          == [ config.age.secrets.fixtureweb.path ];
        message = "fixture: the fixtureweb unit does not read its `unit` secret as an EnvironmentFile";
      }
      {
        # The endpoint model answers what an app needs to know about
        # itself: vaultwarden mounts every route under DOMAIN, so a
        # wrong FQDN or a dropped prefix is a vault nobody can log
        # into. `nixhold.infra.url` is that answer, resolved once in
        # modules/infra/endpoints.nix.
        assertion =
          config.services.vaultwarden.config.DOMAIN == "https://fixture-server.fixture.ts.net/vault";
        message = "fixture: vaultwarden's DOMAIN is not the resolved URL of its own endpoint, got ${config.services.vaultwarden.config.DOMAIN}";
      }
      {
        assertion =
          config.nixhold.infra.url.taskchampion.sync == "https://fixture-server.fixture.ts.net/task";
        message = "fixture: taskchampion's endpoint does not resolve to the node FQDN at /task";
      }
      {
        # Navidrome trusts the identity header from whoever reaches
        # its listener, so the listener must be the socket caddy
        # dials and no loopback port: the address it binds is the
        # backend the endpoint names, and the socket's directory
        # carries caddy's group.
        assertion =
          let
            nd = config.services.navidrome.settings;
            sock = config.nixhold.services.navidrome.network.sockets.web;
          in
          nd.Address == "unix:${sock}"
          && nd.ExtAuth.TrustedSources == "@"
          && nd.BaseUrl == "/music"
          && config.nixhold.infra.url.navidrome.web == "https://fixture-server.fixture.ts.net/music"
          &&
            config.systemd.tmpfiles.settings."10-navidrome".${dirOf sock}.d.group
            == config.services.caddy.group;
        message = "fixture: navidrome's listener, trusted source, base URL or socket group is not the endpoint's";
      }
      {
        # The sync protocol is not HTTP and gets no endpoint: its
        # ports are scoped to the tailscale interface, never opened
        # fleet-wide.
        assertion =
          !(lib.elem 22000 config.networking.firewall.allowedTCPPorts)
          &&
            lib.elem 22000
              config.networking.firewall.interfaces.${config.services.tailscale.interfaceName}.allowedTCPPorts;
        message = "fixture: syncthing's sync port is not scoped to the tailscale interface";
      }
      {
        # HOST scope is a PATH choice and nothing else: this host's
        # `fixtureweb` ciphertext sits under `secrets/<host>/`, so a
        # second host running the same service does not collide with
        # it — while the recipient set is the fleet's, identical to
        # the fleet-scoped secrets above.
        assertion =
          s.scope == "host" && lib.hasSuffix "/secrets/fixture-server/fixtureweb.age" (toString s.sourceFile);
        message = "fixture: host scope must resolve to secrets/<host>/<name>.age, got ${toString s.sourceFile}";
      }
      {
        assertion = s.recipients == config.nixhold.secrets.identity.recipients;
        message = "fixture: a host-scoped secret's recipients differ from a fleet-scoped one's — no recipient set may vary by scope or host";
      }
      {
        # `password` follows `identity`: fleet-scoped, one ciphertext
        # for the whole fleet, declared by the NixOS hosts only.
        assertion =
          config.nixhold.secrets.password.scope == "fleet"
          && lib.hasSuffix "/secrets/password.age" (toString config.nixhold.secrets.password.sourceFile);
        message = "fixture: password is fleet-scoped at secrets/password.age, got ${toString config.nixhold.secrets.password.sourceFile}";
      }
    ];
}
