{ lib, ... }:
let
  inherit (lib) mkOption types;
in
{
  options.nixhold.home.extraModules = mkOption {
    type = types.listOf types.deferredModule;
    default = [ ];
    description = ''
      Per-host home-manager module fragments. Wired into
      `home-manager.users.<identity.username>.imports` by the
      platform-specific half of this module. Host files set
      `nixhold.home.extraModules = [ ./home.nix ];` when they
      need per-host HM additions.

      Forkers who need finer control (different user, scoped
      `mkIf`) bypass this option and set
      `home-manager.users.<user>.imports` directly. The option is
      the convenient path, not the only one.
    '';
  };

  options.nixhold.home.repositoriesDir = mkOption {
    type = types.str;
    default = "~/projects";
    description = ''
      Where `nixhold.repositories.<name>` checkouts live by
      default: `<repositoriesDir>/<name>`. A leading `~` is the
      operator's home. One place to move them all; a single
      repository overrides with its own `path`.
    '';
    example = "~/src";
  };
}
