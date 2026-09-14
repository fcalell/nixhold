# `nixhold.pins`: upstream artifacts the fleet builds from that no
# flake input carries (ARCHITECTURE "Pins"). One committed manifest
# per pin, written by `nixhold update` and read by the module that
# declares it. Platform-independent: imported by the three baselines
# and by the operator's home-manager set, whose declarations the home
# wiring lifts into the host's so the CLI reads one option per host.
{ lib, ... }:
let
  inherit (lib) mkOption types;

  pin = types.submodule (
    { name, config, ... }:
    {
      options = {
        file = mkOption {
          type = types.path;
          description = ''
            The pin file, inside the fleet checkout: the release
            manifest at the pinned version, verbatim. `nixhold update`
            writes it; nothing else does.
          '';
        };

        latest = mkOption {
          type = types.str;
          example = "https://downloads.claude.ai/claude-code-releases/latest";
          description = "URL whose body is the current version string.";
        };

        manifest = mkOption {
          type = types.str;
          example = "https://downloads.claude.ai/claude-code-releases/\${version}/manifest.json";
          description = ''
            URL of the release manifest at a version, `''${version}`
            substituted by the CLI. Its body is JSON carrying a
            `.version` field and becomes `file`.
          '';
        };

        # Lazy on purpose: the declaration evaluates with the file
        # absent, which is what lets `update` read it and write the
        # file; only a consumer forcing `value` hits the throw.
        value = mkOption {
          type = types.attrs;
          readOnly = true;
          default =
            if builtins.pathExists config.file then
              builtins.fromJSON (builtins.readFile config.file)
            else
              throw "nixhold.pins.${name}: no pin file at ${toString config.file} yet; `nixhold update` writes it";
          defaultText = lib.literalMD "`file` parsed";
          description = "The pin file parsed: where the declaring module reads its version and checksums.";
        };
      };
    }
  );
in
{
  options.nixhold.pins = mkOption {
    type = types.attrsOf pin;
    default = { };
    description = ''
      Upstream releases pinned by a committed manifest and moved by
      `nixhold update`, declared by the module that consumes them.
    '';
  };
}
