# `programs.claude-code-native` — Claude Code via Anthropic's
# native installer instead of nixpkgs.
#
# The CLI ships several releases a week; any nixpkgs pin trails
# it. The native installer drops a self-contained binary in
# ~/.local/bin that keeps itself current through Claude's own
# background auto-updater, so no rebuild is ever needed for a
# version bump. Activation only bootstraps: if the binary is
# already present, it is left alone.
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
in
{
  options.programs.claude-code-native = {
    enable = lib.mkEnableOption "Claude Code via the self-updating native installer";
  };

  config = lib.mkIf cfg.enable {
    # The installer also tries to append a PATH export to the
    # shell rc; on a nix-managed (read-only) rc that edit fails
    # harmlessly — this is the durable PATH wiring.
    home.sessionPath = [ "$HOME/.local/bin" ];

    # The installer script re-invokes `curl` by name to download the
    # binary, so curl must be on PATH for the whole pipeline — an
    # absolute-path curl on the fetch alone is not enough.
    home.activation.claude-code-native-bootstrap = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      if [ ! -x "$HOME/.local/bin/claude" ]; then
        run env PATH="${lib.makeBinPath [ pkgs.curl ]}:$PATH" ${pkgs.bash}/bin/bash -c \
          "curl -fsSL https://claude.ai/install.sh | ${pkgs.bash}/bin/bash"
      fi
    '';
  };
}
