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
{ config, lib, ... }:
{
  imports = [
    ./modules/fixtureweb.nix
    ./known-hosts-assertions.nix
    ./repositories.nix
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
