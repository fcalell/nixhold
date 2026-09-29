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

  # `<owner>/<repo>` → `<repo>`. The directory it lands in is
  # `nixhold.home.repositoriesPath`, the same absolute path every
  # declared repository defaults under: the fleet is a checkout the
  # operator works in, so it belongs beside the others rather than
  # loose at the top of their home.
  repoBasename = lib.last (lib.splitString "/" layout.repoUrl);

  # The checkouts `nixhold repo` walks besides the fleet: this host's
  # repositories, "<name>\t<absolute path>" per line.
  expandHome = import ../../lib/expand-home.nix;
  operatorHome = config.users.users.${config.nixhold.identity.username}.home;
  repositories = lib.concatStrings (
    lib.mapAttrsToList (
      name: r: "${name}\t${expandHome operatorHome r.path}\n"
    ) config.nixhold.repositories
  );

  # Baked-in defaults for the CLI's fleet-root resolution
  # (`$NIXHOLD_FLEET` → upward walk from `$PWD` → this). Assigned
  # with `:=` so an exported value from the operator's shell always
  # wins over what the module baked in. The repository list and the
  # hooks are this host's declarations, so they are set outright.
  wrapped = pkgs.writeShellScriptBin "nixhold" ''
    ${lib.optionalString (cfg.fleetDir != null) ''
      : "''${NIXHOLD_FLEET_DEFAULT:=${cfg.fleetDir}}"
      export NIXHOLD_FLEET_DEFAULT
    ''}
    ${lib.optionalString (layout.repoUrl != null) ''
      : "''${NIXHOLD_REPO_URL:=${layout.repoUrl}}"
      export NIXHOLD_REPO_URL
    ''}
    export NIXHOLD_REPOSITORIES=${lib.escapeShellArg repositories}
    ${lib.optionalString (cfg.repo.draft != null) ''
      export NIXHOLD_REPO_DRAFT=${lib.escapeShellArg cfg.repo.draft}
    ''}
    ${lib.optionalString (cfg.repo.resolve != null) ''
      export NIXHOLD_REPO_RESOLVE=${lib.escapeShellArg cfg.repo.resolve}
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
      default =
        if layout.repoUrl == null then null else "${config.nixhold.home.repositoriesPath}/${repoBasename}";
      defaultText = lib.literalExpression ''"''${nixhold.home.repositoriesPath}/''${basename of nixhold.layout.repoUrl}"'';
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

    # The framework drafts and resolves nothing itself: which
    # assistant, if any, runs here is the fleet's choice
    # (ARCHITECTURE "nixhold repo").
    repo = {
      draft = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          An executable that drafts a commit message. It runs in the
          checkout with the short status and the staged diff on stdin
          and prints the message on stdout, which becomes the
          editor's starting text in `nixhold repo commit` and in the
          commit a sync offers. Null starts the editor empty.
        '';
        example = lib.literalExpression ''pkgs.writeShellScript "draft" "exec my-assistant --commit-message"'';
      };

      resolve = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          An executable handed a rebase that stopped on a conflict. It
          runs in the checkout, on the operator's terminal, with a
          brief of the rebase as `$1`; a rebase still in progress
          when it exits is aborted. Null aborts every conflicted
          rebase.
        '';
        example = lib.literalExpression ''pkgs.writeShellScript "resolve" "exec my-assistant \"$1\""'';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ wrapped ];
  };
}
