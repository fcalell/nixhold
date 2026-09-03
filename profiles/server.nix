# nixhold.profiles.server — NixOS server defaults.
#
# Hostkind shape: headless box, runs services, fronted by caddy
# on tailnet (or public when it's the gateway). Imports the
# service + infra modules typical for that shape and flips on
# the always-on baseline (ssh, tailscale).
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
    inputs.nixhold.modules.infra.caddy
    inputs.nixhold.modules.infra.firewall
  ];

  nixhold.services.openssh.enable = lib.mkDefault true;
  nixhold.services.tailscale.enable = lib.mkDefault true;

  # Store hygiene: weekly gc + optimise on every shipped profile.
  nix.gc = {
    automatic = lib.mkDefault true;
    dates = lib.mkDefault "weekly";
    options = lib.mkDefault "--delete-older-than 14d";
  };
  nix.optimise = {
    automatic = lib.mkDefault true;
    dates = lib.mkDefault [ "weekly" ];
  };

  # Server-shape defaults — keep the image small, lean on
  # remote operation.
  documentation.enable = lib.mkDefault false;
  documentation.man.enable = lib.mkDefault false;
  documentation.nixos.enable = lib.mkDefault false;
  services.fwupd.enable = lib.mkDefault false;
  services.fail2ban.enable = lib.mkDefault true;

  environment.systemPackages = with pkgs; [
    git
    htop
    ripgrep
    tmux
    vim
  ];

  system.stateVersion = lib.mkDefault "24.11";
}
