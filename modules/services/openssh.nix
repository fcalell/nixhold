# OpenSSH service — hardened defaults preset.
#
# Operator opts in with `nixhold.services.openssh.enable = true`
# (the `server` profile flips this on by default). The framework
# sets opinionated NixOS defaults; the operator can still
# override individual `services.openssh.settings.*` because the
# defaults use `lib.mkDefault`.
{ config, lib, ... }:
let
  cfg = config.nixhold.services.openssh;
  types' = config.nixhold.types;
in
{
  options.nixhold.services.openssh = {
    enable = lib.mkEnableOption "the hardened OpenSSH preset";
    network = lib.mkOption {
      type = types'.network;
      default = { };
      description = "Per-service port declarations (see `nixhold.types.network`).";
    };
    expose = lib.mkOption {
      type = types'.expose;
      default = { };
      description = ''
        OpenSSH does not produce HTTP endpoints; this option
        exists for shape consistency and is normally left empty.
        Future SSH-over-HTTPS bastions could use it.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
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
  };
}
