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
    { nixhold.services.vaultwarden.implementation = "nixos"; }

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
              SIGNUPS_ALLOWED = lib.mkDefault false;
              SHOW_PASSWORD_HINT = lib.mkDefault false;
              INVITATIONS_ALLOWED = lib.mkDefault false;
            };
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

        (lib.mkIf (cfg.backupDir != null) {
          services.vaultwarden.backupDir = cfg.backupDir;

          # One group per data flow, never a shared "services" group
          # and never `users` (which is every human account's primary
          # group, so it grants nothing narrower than "any local
          # login"). This one carries the nightly copies to whatever
          # syncs them off the box.
          users.groups.backups = { };

          # nixpkgs creates the directory 0770
          # vaultwarden:vaultwarden; the sync service (group backups)
          # has to read it. Setgid so every file the backup writes
          # lands in `backups`. vaultwarden writes its data 0600 and
          # the backup's `cp -r` keeps those modes (umask only removes
          # bits), so group access is granted afterwards, explicitly
          # and nothing more — the copy holds the vault's RSA keys.
          # Symbolic chmod leaves the directory's setgid bit alone.
          systemd.tmpfiles.settings."10-vaultwarden" = {
            ${cfg.backupDir}.d = {
              group = lib.mkForce "backups";
              mode = lib.mkForce "2750";
            };
            # The backup runs as vaultwarden (nixpkgs' unit: no
            # supplementary groups), so the parent has to be
            # traversable by that uid. The consumer owns the parent
            # and typically closes it to a group the writer is not in
            # (`backups` is the readers' group, not the writers'), so
            # the module adds the one bit the writer needs as an ACL:
            # execute only, on the immediate parent, appended to
            # whatever the consumer's own rule set. tmpfiles lets a
            # `+` type share a path with another file's `d` line and
            # runs the two in file order, so the parent's rule must
            # sort before `10-vaultwarden`. The parent must exist:
            # this line never creates it.
            ${dirOf cfg.backupDir}."a+".argument = "u:vaultwarden:x";
          };
          systemd.services.backup-vaultwarden.serviceConfig = {
            UMask = "0027";
            ExecStartPost = "${pkgs.coreutils}/bin/chmod -R u=rwX,g=rX,o= ${cfg.backupDir}";
          };
        })
      ]
    ))
  ];
}
