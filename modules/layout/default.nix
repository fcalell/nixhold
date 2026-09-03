{ lib, ... }:
let
  inherit (lib) mkOption types;

  # `owner/repo` and nothing else. Both consumers *build* strings out
  # of this value — the SSH remote (`git@github.com:<slug>.git`) and
  # `programs.nixhold.fleetDir` (`<operator home>/<basename>`) — so a
  # scheme, a host, or a `.git` suffix silently yields a broken remote
  # and a nonsense checkout path. Constraining the type turns that into
  # an eval error at the one place the value is declared.
  repoSlug =
    let
      shape = types.strMatching "[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*";
    in
    shape
    // {
      name = "repoSlug";
      description = ''GitHub repository slug "owner/repo" (no URL scheme, no host, no ".git" suffix)'';
      check = v: shape.check v && !(lib.hasSuffix ".git" v);
    };
in
{
  # The `layout` contract: the CLI's filesystem coordinates, all
  # readable from any host as `config.nixhold.layout.*`. Every path
  # is defaulted by `mkFleet` as a subpath of the forker's flake
  # root; `mkFleet`'s `layout` arg is optional and overrides
  # per-field. The framework eval never reads from these paths
  # directly — they're CLI-side state. The CLI reads them via `nix
  # eval` to know where to scaffold and where committed
  # secrets/keys live.
  options.nixhold.layout = {
    secrets = mkOption {
      type = types.path;
      description = ''
        Root of the operator's encrypted secrets tree. The
        convention `secrets/hosts/<host>/<name>.age` is enforced —
        the framework derives the per-secret file path from this
        root, `nixhold.fleet.selfName` (the fleet key, not the OS
        hostname), and the attribute name in `nixhold.secrets`.
      '';
      example = lib.literalExpression "./secrets";
    };

    hostsFile = mkOption {
      type = types.path;
      description = ''
        CLI-owned Nix file containing the host topology attrset.
        `nixhold host add` / `nixhold host remove` manipulate this
        file end-to-end.
      '';
      example = lib.literalExpression "./hosts.nix";
    };

    hostsDir = mkOption {
      type = types.path;
      description = ''
        Directory of per-host module directories. `nixhold host add`
        scaffolds `<hostsDir>/<host>/default.nix` there and `nixhold
        host install` writes `<hostsDir>/<host>/facter.json`, the
        default for `nixhold.hardware.facterReport`.
      '';
      example = lib.literalExpression "./hosts";
    };

    modulesDir = mkOption {
      type = types.path;
      description = ''
        Directory for forker-authored modules. The framework does
        not auto-import this; the operator's flake imports modules
        from here directly, either inside profiles or in
        `hosts.<n>.modules`.
      '';
      example = lib.literalExpression "./modules";
    };

    profilesDir = mkOption {
      type = types.path;
      description = ''
        Directory holding operator-authored profiles. Like
        `modulesDir`, the framework does not auto-import from here.
      '';
      example = lib.literalExpression "./profiles";
    };

    keysDir = mkOption {
      type = types.path;
      description = ''
        Directory holding per-host public keys committed to the
        fleet repo (SSH host pubkeys, age recipient pubkeys).
        The framework reads these at eval time to build
        cross-host authorizedKeys lists and agenix recipient
        registries.
      '';
      example = lib.literalExpression "./keys";
    };

    ageRecipient = mkOption {
      type = types.path;
      description = ''
        Path to the operator's age public key. Used as a default
        recipient on every encrypted secret so the operator can
        edit and rekey from any device with the wrapped private
        key.
      '';
      example = lib.literalExpression "./keys/operator.pub";
    };

    ageIdentityWrapped = mkOption {
      type = types.path;
      description = ''
        Path to the operator's passphrase-wrapped age private key.
        Unwrapped only at edit time by `nixhold secret edit`;
        never decrypted to disk during normal activation.
      '';
      example = lib.literalExpression "./keys/operator.age";
    };

    repoUrl = mkOption {
      type = types.nullOr repoSlug;
      default = null;
      description = ''
        The fleet repository as `owner/repo` — a bare slug, not a
        URL: github.com is assumed, and the remote
        (`git@github.com:owner/repo.git`) is built from it, as is
        `programs.nixhold.fleetDir`. It is cloned and pushed over
        SSH using the committed deploy key `keys/repo.key.age`.
        The one layout field nothing can derive from the flake
        root. Required only to build the installer ISO — which
        must reach the fleet repo with nothing but the operator
        passphrase — and unused otherwise.
      '';
      example = "alice/nix";
    };
  };
}
