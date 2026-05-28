{ config, lib, ... }:
let
  inherit (config.nixhold) identity;
in
{
  users.users.${identity.username} = {
    name = lib.mkDefault identity.username;
    home = lib.mkDefault "/Users/${identity.username}";
  };

  # nix-darwin requires `system.primaryUser` for HM activation
  # to know which user owns the home-manager closure.
  system.primaryUser = lib.mkDefault identity.username;
}
