# Vaultwarden service — NixOS implementation.
#
# Reachable behind caddy at `<fqdn>/vault` on whichever network the
# host names in `expose.web.network`; on a tailscale network that is
# the node's own MagicDNS name with the tailscale-issued cert (see
# ARCHITECTURE "Tailnet TLS").
#
# The env secret (ADMIN_TOKEN argon2id + SMTP_*) is declared with
# required = false and wired only once it is `active` (its ciphertext
# exists — `nixhold secret edit <host> vaultwarden`). Until then
# vaultwarden runs without it (no admin panel) so the host still
# evaluates.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.nixhold.services.vaultwarden;

  runtimeDir = "vaultwarden";
  firstRunFile = "first-run.env";
  # What the pre-start writes and the unit reads as its LAST
  # environment file. `RuntimeDirectory` creates the parent, gives the
  # service account write access to it under `ProtectSystem = strict`,
  # and empties it on every stop.
  firstRunEnv = "/run/${runtimeDir}/${firstRunFile}";

  # SIGNUPS_ALLOWED is read at start and has no runtime toggle, so the
  # window is decided at start: open while the vault holds no account,
  # the configured value from the first start after one exists, which
  # on this fleet is the deploy that follows registering. A count that
  # cannot be taken proves nothing, so it leaves the window shut.
  firstRun = pkgs.writeShellScript "vaultwarden-first-run" ''
    set -eu
    out="$RUNTIME_DIRECTORY/${firstRunFile}"
    # An empty file assigns nothing, so the config's own
    # SIGNUPS_ALLOWED stands: this window only ever opens.
    : >"$out"
    db="''${DATABASE_URL:-$DATA_FOLDER/db.sqlite3}"
    users=0
    if [ -e "$db" ]; then
      users="$(${pkgs.sqlite}/bin/sqlite3 "$db" 'select count(*) from users' 2>/dev/null)" || exit 0
    fi
    if [ "$users" = 0 ]; then
      printf 'SIGNUPS_ALLOWED=true\n' >"$out"
    fi
  '';

  # Vaultwarden is one of the apps that has to know its own external
  # origin: with a path in DOMAIN it mounts every route under it and
  # generates absolute links from it. `nixhold.infra.url` is the
  # resolved answer for this service's own endpoint, so the FQDN is
  # not recomputed here from the network's fields.
  #
  # endpoints.nix asserts on every reason an endpoint fails to
  # resolve, and eval still has to produce a value while that
  # assertion is reported — hence the fallback, which is a URL that
  # cannot work rather than an eval abort before the message renders.
  domain = config.nixhold.infra.url.vaultwarden.web or "https://vaultwarden.invalid";
in
{
  # ./default.nix for the namespace; endpoints.nix because this module
  # reads its own endpoint's resolved URL back. Both imports are
  # idempotent — the services index and the infra bundle attach the
  # same two files.
  imports = [
    ./default.nix
    ../../infra/endpoints.nix
  ];

  config = lib.mkMerge [
    {
      nixhold.services.vaultwarden = {
        implementation = "nixos";
        # nixpkgs' producer: its oneshot runs as vaultwarden and
        # `cp -r`s the vault's 0600 files, which is what the
        # framework's post-run chmod on the unit is for.
        backup = {
          unit = "backup-vaultwarden";
          user = "vaultwarden";
        };
      };
    }

    (lib.mkIf cfg.enable (
      lib.mkMerge [
        {
          nixhold.services.vaultwarden = {
            network.ports.rocket = 8222;
            expose.web = {
              protocol = "https";
              backend = "rocket";
              pathPrefix = "/vault";
              # With a path in DOMAIN, vaultwarden mounts ALL routes
              # under /vault/... and expects the prefix passed through
              # — so no stripping (caddy `handle`, not `handle_path`).
              # Websockets (/vault/notifications/hub) ride the same
              # rocket port since vaultwarden 1.29 dropped the
              # standalone websocket server.
              stripPrefix = false;
              extraConfig = "encode zstd gzip";
            };
          };

          services.vaultwarden = {
            enable = true;
            dbBackend = "sqlite";
            config = {
              DOMAIN = domain;
              ROCKET_ADDRESS = "127.0.0.1";
              ROCKET_PORT = 8222;
              # The floor, not the answer: the pre-start below opens
              # signups while the vault has no account.
              SIGNUPS_ALLOWED = lib.mkDefault false;
              SHOW_PASSWORD_HINT = lib.mkDefault false;
              INVITATIONS_ALLOWED = lib.mkDefault false;
            };
          };

          systemd.services.vaultwarden.serviceConfig = {
            RuntimeDirectory = runtimeDir;
            ExecStartPre = [ firstRun ];
            # LAST of the unit's environment files: systemd applies
            # them in the order given and a later assignment wins, so
            # this is what lets the pre-start's answer override the
            # config's SIGNUPS_ALLOWED. `-` so a missing file is not a
            # failed start.
            EnvironmentFile = lib.mkAfter [ "-${firstRunEnv}" ];
          };

          # The unit's environment file, named after the service.
          # `unit` is the whole wiring: the framework appends the
          # decrypted path to systemd.services.vaultwarden's
          # EnvironmentFile once the ciphertext exists, which is
          # exactly what nixpkgs' `services.vaultwarden.environmentFile`
          # would have done (it only concatenates onto the same list),
          # and it drops the service-account ownership — systemd reads
          # the file as root before dropping privileges.
          nixhold.secrets.vaultwarden = {
            unit = "vaultwarden";
            required = false;
            description = "Vaultwarden ADMIN_TOKEN (argon2id) + SMTP_* env.";
          };
        }

        (lib.mkIf (cfg.backup.dir != null) {
          services.vaultwarden.backupDir = cfg.backup.dir;
        })
      ]
    ))
  ];
}
