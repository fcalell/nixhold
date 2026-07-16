# NixOS half of the home-manager wiring: imports HM's NixOS
# module plus the shared wiring in common.nix, and ties HM's
# stateVersion to the system's.
{
  config,
  lib,
  inputs,
  ...
}:
let
  username = config.nixhold.identity.username;
in
{
  imports = [
    inputs.nixhold.inputs.home-manager.nixosModules.home-manager
    ./common.nix
  ];

  config = {
    # home-manager requires a stateVersion. Tie it to the
    # system's so the operator pins one value, not two. mkDefault
    # leaves a per-host HM module free to override.
    home-manager.users.${username}.home.stateVersion = lib.mkDefault config.system.stateVersion;
  };
}
