# `programs.claude-code-native` — Claude Code via Anthropic's
# native installer instead of nixpkgs.
#
# The CLI ships several releases a week; any nixpkgs pin trails it.
# The native installer drops a self-contained binary in ~/.local/bin,
# which is how the tool is meant to be installed.
#
# What the framework does NOT take from the installer is its
# self-updating half. A binary that replaces itself in the background
# is a machine whose software nobody declared: the version that runs
# after a reboot is whatever the network served, it differs per host in
# a fleet that is supposed to be identical, and nothing in the repo
# records it. So the version is an option here, the installer is asked
# for exactly that version, and `DISABLE_AUTOUPDATER` turns the
# background updater off — a bump is an edit to this file (or to the
# fleet's own `version = …`) followed by a deploy, like every other
# package.
#
# Like `programs.nixhold`, this lives under `programs.*` — "is
# the tool installed" is not a framework concern. Default-off;
# hosts opt in from an HM fragment. Pair it with
# `programs.claude-code.package = null` so home-manager keeps
# managing settings/agents without also installing the nixpkgs
# binary.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.claude-code-native;

  # A concrete X.Y.Z is checkable against what is installed; the
  # `stable` / `latest` channels are not (they name a moving target,
  # and `claude --version` prints the version it resolved to). Pinned
  # is the default and the supported shape — a channel degrades to the
  # old "bootstrap only when the binary is missing" behaviour rather
  # than reinstalling on every activation.
  pinned = lib.match "[0-9]+\\.[0-9]+\\.[0-9]+.*" cfg.version != null;

  # A profile's prompt: its files joined by a blank line, so a
  # paragraph shared between personas lives in one file.
  promptFile =
    name: files:
    pkgs.writeText "claude-${name}-prompt.md" (
      lib.concatMapStringsSep "\n\n" (f: lib.removeSuffix "\n" (builtins.readFile f)) files + "\n"
    );
  mcpFile =
    name: servers: pkgs.writeText "claude-${name}-mcp.json" (builtins.toJSON { mcpServers = servers; });

  # The wrapper: the caller's arguments first, the profile's flags
  # after. `--tools` is variadic and swallows every following
  # argument, so it goes last.
  wrapper =
    name: p:
    pkgs.writeShellApplication {
      name = "claude-${name}";
      text = ''
        # A caller with its own prompt or tool set gets the bare binary.
        for a in "$@"; do
          case "$a" in
            --system-prompt* | --append-system-prompt* | --tools) exec claude "$@" ;;
          esac
        done
        chrome=(--no-chrome)
        for a in "$@"; do
          if [ "$a" = --chrome ]; then chrome=(); fi
        done
        ${lib.optionalString (p.memory != null) "export CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1"}
        exec claude "$@" ${
          lib.concatStringsSep " " (
            [
              "--system-prompt-file ${promptFile name p.prompt}"
              "--system-prompt-snapshot off"
            ]
            ++ lib.optional (p.memory != null) "--add-dir ${p.memory}"
            ++ lib.optional (p.mcp != null) "--strict-mcp-config --mcp-config ${mcpFile name p.mcp}"
            ++ lib.optional (p.model != null) "--model ${lib.escapeShellArg p.model}"
            ++ lib.optional (p.effort != null) "--effort ${lib.escapeShellArg p.effort}"
          )
        } "''${chrome[@]}" --tools ${lib.escapeShellArgs p.tools}
      '';
    };

  profile = lib.types.submodule {
    options = {
      prompt = lib.mkOption {
        type = lib.types.listOf lib.types.path;
        description = "Markdown files joined into the whole system prompt, in order.";
      };
      tools = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        description = "The built-in tools the session may load (`--tools`).";
      };
      memory = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          A directory whose `CLAUDE.md` and unconditional
          `.claude/rules/*.md` load at start. A path-scoped rule here
          never fires; those belong in `~/.claude/rules/`.
        '';
      };
      mcp = lib.mkOption {
        type = lib.types.nullOr lib.types.attrs;
        default = null;
        description = ''
          The `mcpServers` map the session alone may reach. Null
          inherits the operator's own servers and connectors.
        '';
      };
      model = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Overrides the operator's model for this persona.";
      };
      effort = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Overrides the operator's effort level for this persona.";
      };
      chrome = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether the Chrome bridge is on; `--chrome` at the call turns it on.";
      };
    };
  };
in
{
  options.programs.claude-code-native = {
    enable = lib.mkEnableOption "Claude Code via the native installer";

    version = lib.mkOption {
      type = lib.types.str;
      default = "2.1.236";
      description = ''
        The Claude Code version the installer is asked for — the
        argument `claude.ai/install.sh` takes. A concrete `X.Y.Z` is
        the point: activation compares it against the installed
        binary and re-runs the installer when they differ, so the
        fleet's version is the one written down here.

        `"stable"` or `"latest"` hand the choice back to the network;
        activation then only bootstraps a missing binary, and which
        version a host ends up on stops being a property of the repo.
      '';
      example = "2.1.236";
    };

    profiles = lib.mkOption {
      type = lib.types.attrsOf profile;
      default = { };
      description = ''
        Personas, one wrapper on PATH each (`claude-<name>`): its own
        system prompt, tool set, memory and MCP set over the same
        binary. Bare `claude` stays the binary as shipped.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = lib.mapAttrsToList wrapper cfg.profiles;

    # The installer also tries to append a PATH export to the
    # shell rc; on a nix-managed (read-only) rc that edit fails
    # harmlessly — this is the durable PATH wiring.
    home.sessionPath = [ "$HOME/.local/bin" ];

    # The other half of pinning: without this the binary updates
    # itself out from under the declared version.
    home.sessionVariables.DISABLE_AUTOUPDATER = "1";

    # The installer script re-invokes `curl` by name to download the
    # binary, so curl must be on PATH for the whole pipeline — an
    # absolute-path curl on the fetch alone is not enough.
    #
    # A failed download is a warning, not an activation failure: the
    # activation script runs under `set -e`, and on a freshly installed
    # host it runs at boot, possibly before the network is up. Aborting
    # there would leave the whole home unmanaged over one optional
    # binary; the next activation retries the bootstrap.
    home.activation.claude-code-native-bootstrap = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      claudeWant=${lib.escapeShellArg cfg.version}
      claudeHave=""
      if [ -x "$HOME/.local/bin/claude" ]; then
        ${
          if pinned then
            ''claudeHave="$("$HOME/.local/bin/claude" --version 2>/dev/null | ${pkgs.coreutils}/bin/head -n1 | ${pkgs.coreutils}/bin/cut -d' ' -f1)" || claudeHave=""''
          else
            ''claudeHave="$claudeWant"''
        }
      fi
      if [ "$claudeHave" != "$claudeWant" ]; then
        run env PATH="${lib.makeBinPath [ pkgs.curl ]}:$PATH" ${pkgs.bash}/bin/bash -o pipefail -c \
          "curl -fsSL https://claude.ai/install.sh | ${pkgs.bash}/bin/bash -s -- $claudeWant" \
          || warnEcho "claude-code-native: install of $claudeWant failed (no network?) — the next activation retries"
      fi
    '';
  };
}
