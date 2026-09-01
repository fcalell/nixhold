# `programs.nixhold` — install the operator CLI system-wide.
#
# Enabled by default on every nixhold-managed host so `nixhold
# <verb>` is on PATH after the first activation. Works on both
# NixOS and nix-darwin (both expose `environment.systemPackages`).
# The option lives under `programs.*` — matching `programs.git`,
# `programs.vim` — because the `nixhold.*` namespace is for
# framework concerns, not "is the CLI installed."
#
# What lands on PATH is a thin wrapper: the fleet directory and
# repo URL known at eval time are baked in as environment
# defaults, so a `nixhold` verb run from anywhere still finds the
# fleet.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.nixhold;
  layout = config.nixhold.layout;

  # `<owner>/<repo>` → `<repo>`. The operator's home comes from
  # `users.users.<operator>.home`, which the platform identity
  # module (co-present in both baseline bundles) always sets — no
  # platform branching here.
  repoBasename = lib.last (lib.splitString "/" layout.repoUrl);
  operatorHome = config.users.users.${config.nixhold.identity.username}.home;

  # Baked-in defaults for the CLI's fleet-root resolution
  # (`$NIXHOLD_FLEET` → upward walk from `$PWD` → this). Assigned
  # with `:=` so an exported value from the operator's shell always
  # wins over what the module baked in.
  wrapped = pkgs.writeShellScriptBin "nixhold" ''
    ${lib.optionalString (cfg.fleetDir != null) ''
      : "''${NIXHOLD_FLEET_DEFAULT:=${cfg.fleetDir}}"
      export NIXHOLD_FLEET_DEFAULT
    ''}
    ${lib.optionalString (layout.repoUrl != null) ''
      : "''${NIXHOLD_REPO_URL:=${layout.repoUrl}}"
      export NIXHOLD_REPO_URL
    ''}
    exec ${cfg.package}/bin/nixhold "$@"
  '';
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

    fleetDir = lib.mkOption {
      # A path *string*, not `types.path`: this names a working
      # tree on this machine that the CLI reads and writes. Typing
      # it as a path would copy the fleet checkout into the store
      # and hand the CLI a read-only copy.
      type = lib.types.nullOr lib.types.str;
      default = if layout.repoUrl == null then null else "${operatorHome}/${repoBasename}";
      defaultText = lib.literalExpression ''"''${operator home}/''${basename of nixhold.layout.repoUrl}"'';
      description = ''
        Where the operator's fleet checkout lives on this machine.
        Last resort in the CLI's fleet-root resolution: baked into
        the installed `nixhold` as `$NIXHOLD_FLEET_DEFAULT`, used
        when neither `$NIXHOLD_FLEET` nor an upward walk from the
        working directory finds a fleet. When the directory is
        missing — a fresh machine after an ISO install — the CLI
        offers to clone `nixhold.layout.repoUrl` into it. Null when
        `repoUrl` is unset, leaving the CLI with no fallback.
      '';
      example = "/home/alice/nix";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ wrapped ];
  };
}
