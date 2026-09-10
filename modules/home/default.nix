{ config, lib, ... }:
let
  inherit (lib) mkOption types;

  expandHome = import ../../lib/expand-home.nix;
  defaults = import ../../lib/defaults.nix;

  # The platform identity module (co-present in both baseline
  # bundles) always sets this, so no platform branching here.
  operatorHome = config.users.users.${config.nixhold.identity.username}.home;
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
    # Shared with the CLI package, which bakes it in for the one
    # path that has no checkout to evaluate (see lib/defaults.nix).
    default = defaults.repositoriesDir;
    description = ''
      Where the operator's checkouts live by default:
      `<repositoriesDir>/<name>` for a `nixhold.repositories.<name>`
      entry, and `<repositoriesDir>/<repo basename>` for the fleet
      checkout itself (`programs.nixhold.fleetDir`). A leading `~` is
      the operator's home. One place to move them all; a single
      repository overrides with its own `path`.
    '';
    example = "~/src";
  };

  # Derived, not a knob: the same directory with `~` resolved. Every
  # consumer compares it against `$PWD`-shaped strings, and reading
  # one value here is what makes the repository default and
  # `programs.nixhold.fleetDir` provably name the same home.
  options.nixhold.home.repositoriesPath = mkOption {
    type = types.str;
    readOnly = true;
    default = expandHome operatorHome config.nixhold.home.repositoriesDir;
    defaultText = lib.literalMD "`nixhold.home.repositoriesDir` with a leading `~` resolved to the operator's home";
    description = ''
      `nixhold.home.repositoriesDir` as an absolute path. Read it
      wherever a checkout location has to be a real path.
    '';
  };
}
