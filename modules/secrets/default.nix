{ config, lib, ... }:
let
  inherit (lib) mkOption types;

  layoutSecrets = config.nixhold.layout.secrets;
  # Lazy: only forced when a secret path is actually computed. On
  # darwin `networking.hostName` defaults to null (mkFleet normally
  # mkDefaults it to the fleet host name), which would otherwise fail
  # string interpolation with an opaque coercion error.
  hostName =
    let
      hn = config.networking.hostName or null;
    in
    if hn == null || hn == "" then
      throw "nixhold.secrets: networking.hostName is unset; it must equal the fleet host name (mkFleet sets it by default)"
    else
      hn;
  username = config.nixhold.identity.username;

  layout = config.nixhold.layout;

  # First line of a committed pubkey file, trailing newline trimmed.
  # age recipients and SSH host pubkeys are single-line; agenix
  # forwards the value to age verbatim, which rejects a stray newline.
  pubkeyLine =
    path:
    let
      m = builtins.match "([^\n]*)\n?" (builtins.readFile path);
    in
    if m == null then
      throw "nixhold.secrets: ${toString path} must contain exactly one key line (found extra lines)"
    else
      builtins.head m;

  # Recipients every secret on THIS host is encrypted to: the operator
  # (so they can edit/rekey from any device with the wrapped key) plus
  # this host's SSH host key (so it decrypts at activation via the
  # default age.identityPaths). Both come from committed pubkeys —
  # paths derived from declared data, never discovered (principle 14).
  # Guarded by pathExists so a host declared before its keys land still
  # evaluates; lint flags the missing host recipient.
  hostPubPath = layout.keysDir + "/hosts/${hostName}/host.pub";
  recipientsForHost =
    lib.optional (builtins.pathExists layout.ageRecipient) (pubkeyLine layout.ageRecipient)
    ++ lib.optional (builtins.pathExists hostPubPath) (pubkeyLine hostPubPath);

  secretSubmodule = types.submodule (
    { name, config, ... }:
    {
      options = {
        owner = mkOption {
          type = types.str;
          example = "vaultwarden";
          description = ''
            Owning unix user for the decrypted file. The literal
            string `"user"` is a shortcut expanding to
            `config.nixhold.identity.username` with mode `"0600"`.
            Service modules pass the service-account name
            (`"vaultwarden"`, `"caddy"`, …); operator-owned secrets
            use `"user"`.
          '';
        };

        mode = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = ''
            File permissions octal. `null` (default) triggers the
            owner-driven default: `"0600"` when `owner == "user"`,
            else `"0400"`. Set explicitly to override.
          '';
          example = "0440";
        };

        description = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = ''
            Free-text description surfaced by
            `nixhold secret list` / `nixhold secret bootstrap`.
            Recommended for every declared secret.
          '';
        };

        template = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = ''
            Starter content the CLI seeds into the editor on
            `nixhold secret bootstrap` when the encrypted file
            does not yet exist (`secret edit` requires an existing
            ciphertext). Typically a key=value scaffold.
          '';
          example = ''
            ADMIN_TOKEN=
          '';
        };

        generator = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = ''
            Shell command the CLI runs to auto-generate the
            initial secret content on
            `nixhold secret bootstrap`. Output captured to
            stdout, encrypted, written. `null` means
            operator-typed.
          '';
          example = "openssl rand -base64 32";
        };

        required = mkOption {
          type = types.bool;
          default = true;
          description = ''
            Whether the encrypted file must exist for activation
            to succeed. `false` allows the host to evaluate before
            the secret has been bootstrapped (useful for
            generated-on-bootstrap secrets the operator hasn't
            populated yet).
          '';
        };

        homePath = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = ''
            Relative path under `$HOME` to symlink at. The home
            module emits
            `home.file.<homePath>.source = mkOutOfStoreSymlink
            <decrypted-path>`. Only meaningful with
            `owner = "user"`; lint enforces. Names beginning with
            `ssh-` additionally get an auto-derived `.pub`
            alongside (via `ssh-keygen -y` at HM activation).
          '';
          example = ".ssh/personal";
        };

        # Derived (readOnly): what the framework computes from the
        # operator-declared fields above. Exposed on the submodule
        # itself so consumers walk one attrset, not two.

        resolvedOwner = mkOption {
          type = types.str;
          readOnly = true;
          description = ''
            `owner` with the `"user"` shortcut expanded to
            `config.nixhold.identity.username`. This is the value
            passed to agenix.
          '';
        };

        resolvedMode = mkOption {
          type = types.str;
          readOnly = true;
          description = ''
            `mode` with `null` resolved to the owner-driven
            default (`"0600"` when `owner == "user"`, else
            `"0400"`).
          '';
        };

        file = mkOption {
          type = types.path;
          readOnly = true;
          description = ''
            Encrypted source file path. Derived as
            `<layout.secrets>/hosts/<hostName>/<name>.age`. This
            path is what agenix reads at activation. No operator
            knob — the convention is the API.
          '';
        };

        recipients = mkOption {
          type = types.listOf types.str;
          readOnly = true;
          description = ''
            Age recipients this secret is encrypted to: the operator
            recipient (`layout.ageRecipient`) plus the owning host's
            SSH host pubkey (`layout.keysDir/hosts/<host>/host.pub`),
            each included when committed. The CLI reads this to
            generate an ephemeral agenix RULES file at edit/rekey
            time; lint reads it to enforce that every host is a
            recipient of the secrets it decrypts. Same value for
            every secret on a host — recipients are per-host, not
            per-secret, in v1.
          '';
        };
      };

      config = {
        resolvedOwner = if config.owner == "user" then username else config.owner;
        resolvedMode =
          if config.mode != null then
            config.mode
          else if config.owner == "user" then
            "0600"
          else
            "0400";
        file = layoutSecrets + "/hosts/${hostName}/${name}.age";
        recipients = recipientsForHost;
      };
    }
  );
in
{
  options.nixhold.secrets = mkOption {
    type = types.attrsOf secretSubmodule;
    default = { };
    description = ''
      Unified secrets declaration. Every secret — service-owned
      or operator-owned — lives here. The framework reads this
      attrset and populates `age.secrets.<name>` for activation,
      `home.file.<homePath>` for HM symlinks (when `homePath` is
      set), and the CLI manifest for
      `nixhold secret list / bootstrap`.

      Each entry is `nixhold.secrets.<name> = { owner, mode?,
      description?, template?, generator?, required?, homePath? }`.
      The encrypted file path is derived (not configurable) per
      the `secrets/hosts/<host>/<name>.age` convention.
    '';
  };

  # A required secret with no committed ciphertext would otherwise
  # surface as agenix's raw "path does not exist" at build time;
  # fail with the fix spelled out instead. `required = false`
  # secrets are filtered out of `age.secrets` by the platform
  # halves until their ciphertext lands.
  config.assertions = lib.mapAttrsToList (name: s: {
    assertion = !s.required || builtins.pathExists s.file;
    message = ''
      nixhold.secrets.${name}: missing ciphertext ${toString s.file}.
      Run `nixhold secret bootstrap <host>` (or declare it with
      `required = false` until it is bootstrapped).
    '';
  }) config.nixhold.secrets;
}
