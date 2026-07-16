# Darwin half of the home-manager wiring: imports HM's darwin
# module plus the shared wiring in common.nix.
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
    inputs.nixhold.inputs.home-manager.darwinModules.home-manager
    ./common.nix
  ];

  config = {
    # home-manager requires a stateVersion. nix-darwin's
    # `system.stateVersion` is an integer on a different scale, so
    # (unlike the NixOS half) we can't tie HM's release-string
    # stateVersion to it — default to the framework baseline.
    # mkDefault leaves a per-host HM module free to override.
    home-manager.users.${username}.home.stateVersion = lib.mkDefault "24.11";
  };
}
