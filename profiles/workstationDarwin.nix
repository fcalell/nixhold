# nixhold.profiles.workstationDarwin — macOS workstation defaults.
#
# Hostkind shape: operator's daily-driver Mac. It pulls in tailscale
# so the Mac is a fleet member on the same terms as the Linux hosts;
# no NixOS infra module applies (a workstation terminates no fleet
# HTTP, and Darwin has its own service surface). The framework's
# baseline already wires home-manager via
# `darwinModules.home-manager`.
{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:
{
  imports = [ inputs.nixhold.modules.services.darwin.tailscale ];

  nixhold.services.tailscale.enable = lib.mkDefault true;

  # A seat: the operator's declared repositories are checked out here.
  nixhold.home.checkouts = lib.mkDefault true;

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

  programs.zsh.enable = lib.mkDefault true;

  # The darwin half of "Sudo asks": every elevation prompts, and on a
  # Mac the prompt the operator already carries is the fingerprint
  # reader. `sudo_local` is the drop-in nix-darwin manages, so this
  # survives the OS rewriting /etc/pam.d/sudo on update.
  security.pam.services.sudo_local.touchIdAuth = lib.mkDefault true;

  # `git`: the CLI clones the operator's repositories.
  environment.systemPackages = [ pkgs.git ];

  system.stateVersion = lib.mkDefault 5;
}
