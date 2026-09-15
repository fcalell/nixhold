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
    inputs.nixhold.modules.services.nixos.openssh
    inputs.nixhold.modules.services.nixos.tailscale
    # No infra modules: caddy, the firewall and backup publishing
    # follow a service's declarations on any NixOS host, so the
    # baseline imports them (modules/baseline-nixos.nix).
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

  # A headless box has one wired port and no radio: networkd with DHCP
  # on it, whose online signal is the link itself (NetworkManager
  # would queue tailscaled behind its wait-online at every boot).
  networking.useNetworkd = lib.mkDefault true;

  # Pressure-based OOM on the root slice: NixOS ships oomd with every
  # scope off, so `enable` alone watches nothing. Units in
  # system.slice are left to the kernel killer.
  systemd.oomd = {
    enable = lib.mkDefault true;
    enableRootSlice = lib.mkDefault true;
  };
  # fail2ban is not a profile decision: the openssh module turns it on
  # for a host that is actually on an internet-typed network, and a
  # tailnet-only server has nothing reaching sshd to ban.

  # `git`: the CLI clones the operator's repositories.
  environment.systemPackages = [ pkgs.git ];

  system.stateVersion = lib.mkDefault "24.11";
}
