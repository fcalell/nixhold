# OpenSSH service — option namespace.
#
# Split from the implementation (./nixos.nix) because the namespace
# and the implementation have different scopes: `nixhold.services` is
# readable on every nixhold host (`nixhold status` walks it, so both
# baselines import the services index), while the implementation is
# NixOS-only and is attached by the profiles that want it.
{ config, lib, ... }:
let
  cfg = config.nixhold.services.openssh;
  types' = config.nixhold.types;
in
{
  options.nixhold.services.openssh = {
    enable = lib.mkEnableOption "the hardened OpenSSH preset";

    implementation = lib.mkOption {
      internal = true;
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Set by the platform implementation module when one is
        attached. Enabling a service whose implementation this host
        never imported would otherwise be a silent no-op.
      '';
    };

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

  config.assertions = lib.optional (cfg.enable && cfg.implementation == null) {
    assertion = false;
    message = "nixhold.services.openssh is enabled but no implementation is attached on this host — import `nixhold.modules.services.openssh` (NixOS only).";
  };
}
