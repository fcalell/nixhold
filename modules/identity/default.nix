{ lib, ... }:
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
}
