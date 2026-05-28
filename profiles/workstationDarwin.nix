# nixhold.profiles.workstationDarwin — macOS workstation defaults.
#
# Hostkind shape: operator's daily-driver Mac. No NixOS infra
# modules apply (Darwin has its own service surface). The
# framework's baseline already wires home-manager via
# `darwinModules.home-manager`.
{ lib, pkgs, ... }:
{
  nix.settings = {
    experimental-features = lib.mkDefault [
      "nix-command"
      "flakes"
    ];
  };

  nixpkgs.config.allowUnfree = lib.mkDefault true;

  programs.zsh.enable = lib.mkDefault true;

  environment.systemPackages = with pkgs; [
    git
    ripgrep
  ];

  system.stateVersion = lib.mkDefault 5;
}
