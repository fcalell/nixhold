# `programs.nixhold` — install the operator CLI system-wide.
#
# Enabled by default on every nixhold-managed host so `nixhold
# <verb>` is on PATH after the first activation. Works on both
# NixOS and nix-darwin (both expose `environment.systemPackages`).
# The option lives under `programs.*` — matching `programs.git`,
# `programs.vim` — because the `nixhold.*` namespace is for
# framework concerns, not "is the CLI installed."
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.nixhold;
in
{
  options.programs.nixhold = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether to install the `nixhold` CLI into the system
        environment. On by default for every host.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = import ../../cli { inherit pkgs; };
      defaultText = lib.literalExpression "nixhold's bundled CLI";
      description = "The nixhold CLI package to install.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];
  };
}
