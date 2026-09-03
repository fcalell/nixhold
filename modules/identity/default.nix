{ config, lib, ... }:
let
  inherit (lib) mkOption types;
in
{
  options.nixhold.identity = {
    username = mkOption {
      type = types.str;
      description = ''
        Primary operator username. Drives the system user
        (NixOS + nix-darwin), home directory, agenix file owner,
        SSH user, and the default `home-manager.users.<name>`
        attribute. Forkers replace this once in `mkFleet`'s
        `identity` arg; the framework reads it from every host.
      '';
      example = "alice";
    };

    fullName = mkOption {
      type = types.str;
      description = ''
        Operator's full name. Used for the system user
        description (gecos) and the git author name.
      '';
      example = "Alice Example";
    };

    email = mkOption {
      type = types.str;
      description = "Operator email. Used as the git author email.";
      example = "alice@example.com";
    };
  };

  # Cross-platform auto-wiring. NixOS and nix-darwin both expose
  # `nix.settings` — mkDefault so a host or profile can override
  # without `mkForce`. `root` stays in trusted-users: writing the
  # setting replaces nix.conf's built-in `trusted-users = root`.
  # Flakes are on everywhere because every CLI verb needs them on
  # every host.
  config.nix.settings = {
    trusted-users = lib.mkDefault [
      "root"
      config.nixhold.identity.username
    ];
    experimental-features = lib.mkDefault [
      "nix-command"
      "flakes"
    ];
  };
}
