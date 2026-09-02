# nixhold.profiles.desktopLinux — NixOS hyprland desktop defaults.
#
# Hostkind shape: operator's daily-driver Linux box. Hyprland +
# the supporting wayland stack. Pulls in openssh + tailscale so
# the desktop is reachable from the rest of the fleet, but no
# caddy/firewall (a desktop doesn't terminate fleet HTTP).
{
  inputs,
  lib,
  pkgs,
  ...
}:
{
  imports = [
    inputs.nixhold.modules.services.openssh
    inputs.nixhold.modules.services.tailscale
  ];

  nixhold.services.openssh.enable = lib.mkDefault true;
  nixhold.services.tailscale.enable = lib.mkDefault true;

  nix.settings = {
    experimental-features = lib.mkDefault [
      "nix-command"
      "flakes"
    ];
    auto-optimise-store = lib.mkDefault true;
  };

  nixpkgs.config.allowUnfree = lib.mkDefault true;

  programs.hyprland = {
    enable = lib.mkDefault true;
    xwayland.enable = lib.mkDefault true;
  };

  # Wayland desktop essentials.
  security.polkit.enable = lib.mkDefault true;
  security.rtkit.enable = lib.mkDefault true;

  services.pipewire = {
    enable = lib.mkDefault true;
    alsa.enable = lib.mkDefault true;
    alsa.support32Bit = lib.mkDefault true;
    pulse.enable = lib.mkDefault true;
  };

  xdg.portal = {
    enable = lib.mkDefault true;
    extraPortals = with pkgs; [ xdg-desktop-portal-hyprland ];
  };

  fonts.packages = with pkgs; [
    noto-fonts
    noto-fonts-color-emoji
  ];

  environment.systemPackages = with pkgs; [
    git
    htop
    ripgrep
    tmux
    vim
  ];

  system.stateVersion = lib.mkDefault "24.11";
}
