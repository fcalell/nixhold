# nixhold.profiles.workstationDarwin — macOS workstation defaults.
#
# Hostkind shape: operator's daily-driver Mac. No NixOS infra
# modules apply (Darwin has its own service surface). The
# framework's baseline already wires home-manager via
# `darwinModules.home-manager`.
{
  config,
  lib,
  pkgs,
  ...
}:
{
  # Store hygiene: weekly gc + optimise, as on the NixOS profiles.
  # launchd needs an explicit interval or the timers silently no-op;
  # both follow `nix.enable`, which nix-darwin asserts they require.
  nix.gc = {
    automatic = lib.mkDefault config.nix.enable;
    options = lib.mkDefault "--delete-older-than 14d";
    interval = lib.mkDefault {
      Weekday = 0;
      Hour = 3;
      Minute = 15;
    };
  };
  nix.optimise = {
    automatic = lib.mkDefault config.nix.enable;
    interval = lib.mkDefault {
      Weekday = 0;
      Hour = 3;
      Minute = 30;
    };
  };

  nixpkgs.config.allowUnfree = lib.mkDefault true;

  programs.zsh.enable = lib.mkDefault true;

  environment.systemPackages = with pkgs; [
    git
    ripgrep
  ];

  system.stateVersion = lib.mkDefault 5;
}
