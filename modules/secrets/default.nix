{ config, lib, ... }:
let
  inherit (lib) mkOption types;

  layoutSecrets = config.nixhold.layout.secrets;
  # The fleet attribute key, NOT `config.networking.hostName`: the OS
  # hostname is only mkDefault'ed to it, so a host renamed by an MDM
  # policy (or by the operator) would otherwise silently re-point its
  # ciphertext paths and its recipient set at a host that does not
  # exist. Lazy: only forced when a secret path is actually computed.
  hostName =
    let
      hn = config.nixhold.fleet.selfName;
    in
    if hn == null || hn == "" then
      throw "nixhold.secrets: nixhold.fleet.selfName is unset; mkFleet sets it from the host's key in its `hosts` argument"
    else
      hn;
  username = config.nixhold.identity.username;

  layout = config.nixhold.layout;

  # Single-line pubkey reader shared with modules/fleet (age rejects a
  # stray newline in a recipient just as sshd does in authorized_keys).
  pubkeyLine = import ../../lib/pubkey-line.nix "nixhold.secrets";

  # Recipients every secret on THIS host is encrypted to: the operator
  # (so they can edit/rekey from any device with the wrapped key) plus
  # this host's SSH host key (so it decrypts at activation via the
  # default age.identityPaths). Both come from committed pubkeys —
  # paths derived from declared data, never discovered (principle 14).
  # Guarded by pathExists so a host declared before its keys land still
  # evaluates; lint flags the missing host recipient.
  hostPubPath = layout.keysDir + "/hosts/${hostName}/host.pub";

  # The default generator of an `sshKey` secret: a fresh ed25519 key
  # on stdout (what gets encrypted), its pubkey on stderr (what the
  # operator registers wherever the key is used). ssh-keygen insists
  # on writing to disk, so the pair is made in a private dir the trap
  # removes on every exit path.
  keygen = name: ''
    (
      umask 077
      d="$(mktemp -d)" || exit 1
      trap 'rm -rf "$d"' EXIT INT TERM
      ssh-keygen -q -t ed25519 -N "" -C "${hostName}-${name}" -f "$d/key" || exit 1
      cat "$d/key" || exit 1
      { echo "pubkey of ${hostName}/${name} (register it where this key is used):"; cat "$d/key.pub"; } >&2
    )
  '';
  recipientsForHost =
    lib.optional (builtins.pathExists layout.ageRecipient) (pubkeyLine layout.ageRecipient)
    ++ lib.optional (builtins.pathExists hostPubPath) (pubkeyLine hostPubPath);

  secretSubmodule = types.submodule (
    { name, config, ... }:
    {
      options = {
        owner = mkOption {
          type = types.str;
          default = "user";
          example = "vaultwarden";
          description = ''
            Owning unix user for the decrypted file. The literal
            string `"user"` (the default) is a shortcut expanding to
            `config.nixhold.identity.username` with mode `"0600"`.
            Service modules pass the service-account name
            (`"vaultwarden"`, `"caddy"`, …); operator-owned secrets
            declare nothing.
          '';
        };

        sshKey = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Marks the secret as an SSH private key: the home module
            derives `~/<homePath>.pub` via `ssh-keygen -y` at HM
            activation, `homePath` defaults to `".ssh/<name>"`, and
            `generator` defaults to an ed25519 keygen (on a terminal
            `nixhold secret edit` offers to paste an existing key
            instead). Only meaningful with `owner = "user"`. Behavior
            is triggered by this option, never by the secret's name.
          '';
        };

        sshIdentity = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Marks THE operator's outbound SSH identity on this host
            (implies `sshKey`; at most one per host). The home
            module wires it as `IdentityFile` for fleet-peer
            matchBlocks; the CLI commits its derived pubkey as
            `keys/hosts/<host>/identity.pub`, which defaults
            `fleet.hosts.<host>.loginPubkey`.
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
            Free-text description surfaced by `nixhold status`
            and `nixhold secret edit`.
            Recommended for every declared secret.
          '';
        };

        template = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = ''
            Starter content `nixhold secret edit` seeds into the
            editor when the encrypted file does not yet exist.
            Typically a key=value scaffold.
          '';
          example = ''
            ADMIN_TOKEN=
          '';
        };

        generator = mkOption {
          type = types.nullOr types.str;
          defaultText = lib.literalMD "an ed25519 keygen when `sshKey`, else `null`";
          description = ''
            Shell command `nixhold secret edit` runs to generate
            the initial secret content when the encrypted file
            does not yet exist. Output captured from stdout,
            encrypted, written; stderr reaches the operator. `null`
            means operator-typed.
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
          defaultText = lib.literalMD ''`".ssh/<name>"` when `sshKey = true`, else `null`'';
          description = ''
            Relative path under `$HOME` to symlink at. The home
            module emits
            `home.file.<homePath>.source = mkOutOfStoreSymlink
            <decrypted-path>`. Only meaningful with
            `owner = "user"`; lint enforces. Secrets with
            `sshKey = true` additionally get an auto-derived
            `.pub` alongside (via `ssh-keygen -y` at HM
            activation).
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

        sourceFile = mkOption {
          type = types.path;
          readOnly = true;
          description = ''
            The ciphertext's place in the fleet checkout, derived
            as `<layout.secrets>/hosts/<host>/<name>.age`. Being a
            subpath of the checkout, it carries a reference to the
            *whole* checkout, so it is only ever used for existence
            checks and operator-facing messages — never handed to a
            derivation or an activation script. Activation reads
            `file`.
          '';
        };

        file = mkOption {
          type = types.path;
          readOnly = true;
          description = ''
            The ciphertext as agenix reads it at activation:
            `sourceFile` re-added to the store by content
            (`builtins.path`), so it is a store path holding that
            one file. agenix interpolates this into its activation
            script, which makes it a runtime dependency of
            `system.build.toplevel` — handing over the checkout
            subpath instead would put the entire fleet source (every
            host's ciphertexts, the wrapped operator identity, the
            host-key escrows) into every host's world-readable
            `/nix/store`. Same idiom as the installer ISO's `bake`.
            Falls back to `sourceFile` while the ciphertext does not
            exist yet — there is no content to copy then, and the
            assertion below is what reports it. No operator knob —
            the convention is the API.
          '';
        };

        active = mkOption {
          type = types.bool;
          readOnly = true;
          description = ''
            Whether this secret participates in activation:
            `required`, or already bootstrapped (ciphertext exists).
            The platform halves populate `age.secrets` and the home
            modules emit symlinks only for active secrets, so a
            `required = false` secret declared ahead of its
            ciphertext never dangles.
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
        # sshIdentity is the stronger claim; declaring it alone is
        # enough (an explicit sshKey definition still wins).
        sshKey = lib.mkDefault config.sshIdentity;
        homePath = lib.mkDefault (if config.sshKey then ".ssh/${name}" else null);
        generator = lib.mkDefault (if config.sshKey then keygen name else null);
        resolvedOwner = if config.owner == "user" then username else config.owner;
        resolvedMode =
          if config.mode != null then
            config.mode
          else if config.owner == "user" then
            "0600"
          else
            "0400";
        sourceFile = layoutSecrets + "/hosts/${hostName}/${name}.age";
        file =
          if builtins.pathExists config.sourceFile then
            builtins.path {
              path = config.sourceFile;
              name = "nixhold-secret-${hostName}-${name}.age";
            }
          else
            config.sourceFile;
        active = config.required || builtins.pathExists config.sourceFile;
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
  config.assertions =
    lib.concatLists (
      lib.mapAttrsToList (name: s: [
        {
          assertion = !s.required || builtins.pathExists s.sourceFile;
          message = ''
            nixhold.secrets.${name}: missing ciphertext ${toString s.sourceFile}.
            Run `nixhold secret edit <host>` (or declare it with
            `required = false` until it is provisioned).
          '';
        }
        {
          assertion = s.homePath == null || s.owner == "user";
          message = ''
            nixhold.secrets.${name}: homePath is only meaningful with
            owner = "user" (got owner = "${s.owner}").
          '';
        }
        {
          assertion = !s.sshKey || s.owner == "user";
          message = ''
            nixhold.secrets.${name}: sshKey marks an operator-owned
            key; it requires owner = "user" (got owner = "${s.owner}").
          '';
        }
        {
          assertion = !s.sshIdentity || s.sshKey;
          message = ''
            nixhold.secrets.${name}: sshIdentity implies sshKey; do
            not set sshKey = false on the identity secret.
          '';
        }
      ]) config.nixhold.secrets
    )
    ++ [
      {
        assertion = lib.count (s: s.sshIdentity) (lib.attrValues config.nixhold.secrets) <= 1;
        message = ''
          nixhold.secrets: at most one secret per host may set
          sshIdentity = true (it becomes the single IdentityFile for
          fleet-peer ssh).
        '';
      }
    ];
}
