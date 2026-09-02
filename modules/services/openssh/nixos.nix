# OpenSSH service — NixOS implementation of the hardened preset.
#
# What `nixhold.modules.services.openssh` resolves to: a profile
# importing it gets the option namespace (./default.nix, the same
# module the services index attaches) plus the config below. Operator
# opts in with `nixhold.services.openssh.enable = true` (the `server`
# profile flips this on by default). The framework sets opinionated
# NixOS defaults; the operator can still override individual
# `services.openssh.settings.*` because the defaults use
# `lib.mkDefault`.
{ config, lib, ... }:
let
  cfg = config.nixhold.services.openssh;
in
{
  imports = [ ./default.nix ];

  config = lib.mkMerge [
    { nixhold.services.openssh.implementation = "nixos"; }

    (lib.mkIf cfg.enable {
      services.openssh = {
        enable = true;
        openFirewall = lib.mkDefault true;
        settings = {
          PasswordAuthentication = lib.mkDefault false;
          KbdInteractiveAuthentication = lib.mkDefault false;
          PermitRootLogin = lib.mkDefault "prohibit-password";
          X11Forwarding = lib.mkDefault false;
        };
      };
    })
  ];
}
