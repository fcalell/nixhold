{ config, lib, ... }:
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
        convention is enforced, not configurable:
        `secrets/<host>/<name>.age` for a host-scoped secret and
        `secrets/<name>.age` for a fleet-scoped one — the framework
        derives the per-secret file path from this root, the secret's
        `scope`, `nixhold.fleet.selfName` (the fleet key, not the OS
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
        Directory holding the fleet's committed public key material:
        the operator's age recipients (`operator.pub`) and their
        passphrase-wrapped identity (`operator.age`), the fleet age
        key (`fleet.pub` and the operator-wrapped `fleet.key.age`),
        the operator's ssh login pubkeys (`login.pub`), and one ssh
        host pubkey per machine for known_hosts pinning
        (`hosts/<host>.pub`). The framework reads the public halves at
        eval time to build authorizedKeys lists, agenix recipient sets
        and known_hosts entries.
      '';
      example = lib.literalExpression "./keys";
    };

    ageRecipient = mkOption {
      type = types.path;
      description = ''
        Path to the operator's age recipients — ONE RECIPIENT PER
        LINE, every line a route to the same operator. A FIDO2
        hardware token contributes an `age1fido2-hmac1…` line; a
        passphrase-wrapped identity contributes its `age1…` line; a
        fleet may commit both, and blank lines and `#` comments are
        ignored. Every line is added as a default recipient on every
        encrypted secret, so the operator can edit and rekey from any
        device holding any one of the routes.
      '';
      example = lib.literalExpression "./keys/operator.pub";
    };

    ageIdentityWrapped = mkOption {
      type = types.nullOr types.path;
      # Principle 14 exception, named like the committed-pubkey
      # readers: whether the operator commits a wrapped identity is
      # not something a fleet should have to declare twice, and the
      # file's presence is the declaration. Nothing is *discovered*
      # here — the path is computed from `keysDir`, and `pathExists`
      # only answers whether that one computed path is populated.
      default =
        let
          p = config.nixhold.layout.keysDir + "/operator.age";
        in
        if builtins.pathExists p then p else null;
      defaultText = lib.literalMD "`<keysDir>/operator.age` when that file is committed, else `null`";
      description = ''
        Path to the operator's passphrase-wrapped age private key,
        or `null` for a fleet whose only route is a hardware token.
        Unwrapped only at edit time by `nixhold secret edit`; never
        decrypted to disk during normal activation. It is one route
        among the recipients in `ageRecipient`, not the route: a
        token-only fleet commits no wrapped identity at all, and a
        fleet that commits both can fall back from one to the other.
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
        SSH using the fleet's own `identity` key, the one the forge
        already authenticates. The one layout field nothing can
        derive from the flake root. Required only to build the
        installer ISO — which must reach the fleet repo with nothing
        but the operator's age route (their token, or their
        passphrase) — and unused otherwise.
      '';
      example = "alice/nix";
    };
  };
}
