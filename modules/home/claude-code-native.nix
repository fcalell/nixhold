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
  };

  config = lib.mkIf cfg.enable {
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
