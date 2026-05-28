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
}
