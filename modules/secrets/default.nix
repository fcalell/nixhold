{ config, lib, ... }:
let
  inherit (lib) mkOption types;

  layoutSecrets = config.nixhold.layout.secrets;
  sharedTypes = config.nixhold.types;
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
  # The one committed key file that is a LIST rather than a line: the
  # operator reaches their secrets by however many routes they hold
  # (hardware token, passphrase-wrapped identity, or both), and each
  # is a recipient of its own.
  pubkeyLines = import ../../lib/pubkey-lines.nix;

  # Recipients EVERY ciphertext under `layout.secrets` is encrypted
  # to, host-scoped and fleet-scoped alike: every operator route in
  # `layout.ageRecipient` (so they can edit and rekey from any device
  # that holds one of them) plus the one fleet key in
  # `keys/fleet.pub`, which every host holds at
  # `/etc/nixhold/fleet.key` and decrypts with at activation. The set
  # never varies per host, so adding or removing a host rekeys
  # nothing. Both come from committed pubkeys — paths derived from
  # declared data, never discovered (principle 14) — and both are
  # guarded by pathExists so a fleet evaluates before its keys land;
  # lint flags a missing one.
  fleetPubPath = layout.keysDir + "/fleet.pub";

  # The default generator of an `sshKey` secret: a fresh key of the
  # secret's `sshKeyType` on stdout (what gets encrypted), its pubkey
  # on stderr (what the operator registers wherever the key is used).
  # rsa is 4096 bits: CodeCommit, the forge that forces rsa at all,
  # takes 2048 to 16384, and there is no reason to sit at the floor.
  # ssh-keygen insists
  # on writing to disk, so the pair is made in a private dir the trap
  # removes on every exit path. The key's comment — which outlives
  # the mint, in `authorized_keys` and on every forge — names the
  # thing that owns it: a fleet secret is the fleet's, so stamping
  # the host that happened to run the generator would misdescribe it
  # on every OTHER host from then on.
  keygenFlags = {
    ed25519 = "-t ed25519";
    rsa = "-t rsa -b 4096";
  };
  keygen = scope: name: type: ''
    (
      umask 077
      d="$(mktemp -d)" || exit 1
      trap 'rm -rf "$d"' EXIT INT TERM
      ssh-keygen -q ${keygenFlags.${type}} -N "" -C "${scopeLabel scope}-${name}" -f "$d/key" || exit 1
      cat "$d/key" || exit 1
      { echo "pubkey of ${scopeLabel scope}/${name} (register it where this key is used):"; cat "$d/key.pub"; } >&2
    )
  '';
  # Who a secret of this scope belongs to, for operator-facing labels.
  scopeLabel = scope: if scope == "fleet" then "fleet" else hostName;
  fleetRecipients =
    lib.optionals (builtins.pathExists layout.ageRecipient) (pubkeyLines layout.ageRecipient)
    ++ lib.optional (builtins.pathExists fleetPubPath) (pubkeyLine fleetPubPath);

  secretSubmodule = types.submodule (
    { name, config, ... }:
    {
      options = {
        owner = mkOption {
          type = types.str;
          defaultText = lib.literalMD ''`"root"` when `unit` is set, else `"user"`'';
          example = "vaultwarden";
          description = ''
            Owning unix user for the decrypted file. The literal
            string `"user"` is a shortcut expanding to
            `config.nixhold.identity.username` with mode `"0600"`;
            it is the default for everything but a `unit` secret,
            which systemd reads as root. Service modules pass the
            service-account name (`"vaultwarden"`, `"caddy"`, …);
            operator-owned secrets declare nothing.
          '';
        };

        sshKey = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Marks the secret as an SSH private key: the home module
            derives `~/<homePath>.pub` via `ssh-keygen -y` at HM
            activation, `homePath` defaults to `".ssh/<name>"`, and
            `generator` defaults to a keygen of `sshKeyType` (on a
            terminal `nixhold secret edit` offers to paste an
            existing key instead). Only meaningful with
            `owner = "user"`. Behavior is triggered by this option,
            never by the secret's name.
          '';
        };

        sshKeyType = mkOption {
          type = sharedTypes.sshKeyType;
          default = "ed25519";
          description = ''
            Algorithm of an `sshKey` secret's default generator:
            ed25519, or rsa (4096 bits) for a forge that cannot take
            ed25519. Read only when `sshKey = true`.
          '';
        };

        scope = mkOption {
          type = types.enum [
            "host"
            "fleet"
          ];
          default = "host";
          description = ''
            Where the secret's ciphertext lives, and nothing else —
            every host decrypts with the same fleet key, so scope is
            a PATH choice, not an access one. `"host"` (default): one
            ciphertext per host at
            `<layout.secrets>/<host>/<name>.age`, so two hosts running
            the same service do not collide. `"fleet"`: ONE ciphertext
            for the whole fleet at `<layout.secrets>/<name>.age`,
            which every declaring host reads the same bytes of.
            `recipients` is identical either way.
          '';
        };

        unit = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = ''
            Name of a systemd unit this secret is the environment
            file of (NixOS only). The platform half sets
            `systemd.services.<unit>.serviceConfig.EnvironmentFile`
            to the decrypted path once the secret is `active`, so a
            service module declares "this unit reads these
            KEY=value pairs" and nothing else. systemd reads the
            file as root before dropping privileges, so `owner`
            defaults to root (mode `0400`). Mutually exclusive with
            `homePath` / `sshKey`: an environment file is not a
            thing the operator holds in `$HOME`.
          '';
          example = "vaultwarden";
        };

        category = mkOption {
          type = types.enum [
            "framework"
            "service"
            "repository"
            "operator"
          ];
          defaultText = lib.literalMD ''`"service"` when `unit` is set, else `"operator"`'';
          description = ''
            Who declared this secret, for the CLI's grouping and for
            reading a host's secret surface at a glance. Set by the
            declarer: `framework` for the ones the framework itself
            declares on every host, `service` for a service module's,
            `repository` for the env file of a
            `nixhold.repositories` entry, `operator` (the default)
            for anything a fleet declares directly.
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
          defaultText = lib.literalMD "a keygen of `sshKeyType` when `sshKey`, else `null`";
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
          example = ".ssh/identity";
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
            from `scope`: `<layout.secrets>/<host>/<name>.age`
            for a host secret, `<layout.secrets>/<name>.age`
            for a fleet one. Being a
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
            wrapped fleet key) into every host's world-readable
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
            Age recipients this secret is encrypted to: every
            operator route committed in `layout.ageRecipient` (one
            per line — token, passphrase-wrapped identity, or both)
            plus the fleet key's recipient line
            (`layout.keysDir/fleet.pub`), each included when
            committed. The CLI reads this to generate an ephemeral
            age recipient set at edit/rekey time. The same value for
            every secret of every host and every scope: one fleet
            key, so no recipient set varies per host and `nixhold
            secret rekey` is needed only when the operator's own
            routes change or the fleet key rotates.
          '';
        };
      };

      config = {
        homePath = lib.mkDefault (if config.sshKey then ".ssh/${name}" else null);
        generator = lib.mkDefault (
          if config.sshKey then keygen config.scope name config.sshKeyType else null
        );
        # Defaults that depend on another option are stated at
        # option-default priority (mkOptionDefault), not mkDefault:
        # a service module writing `owner = lib.mkDefault "caddy"`
        # must win, and two mkDefaults would tie instead.
        owner = lib.mkOptionDefault (if config.unit != null then "root" else "user");
        category = lib.mkOptionDefault (if config.unit != null then "service" else "operator");
        resolvedOwner = if config.owner == "user" then username else config.owner;
        resolvedMode =
          if config.mode != null then
            config.mode
          else if config.owner == "user" then
            "0600"
          else
            "0400";
        # One ciphertext per host, or one for the fleet. A fleet
        # secret sits at the root of the tree with no host component:
        # the whole point of it is that every declaring host decrypts
        # the same bytes.
        sourceFile =
          if config.scope == "fleet" then
            layoutSecrets + "/${name}.age"
          else
            layoutSecrets + "/${hostName}/${name}.age";
        file =
          if builtins.pathExists config.sourceFile then
            builtins.path {
              path = config.sourceFile;
              name = "nixhold-secret-${if config.scope == "fleet" then "fleet" else hostName}-${name}.age";
            }
          else
            config.sourceFile;
        active = config.required || builtins.pathExists config.sourceFile;
        recipients = fleetRecipients;
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

      Each entry is `nixhold.secrets.<name> = { scope?, category?,
      owner?, mode?, description?, template?, generator?,
      required?, homePath?, sshKey?, unit? }`. The encrypted file
      path is derived (not configurable) from `scope`:
      `secrets/<host>/<name>.age` for a host secret,
      `secrets/<name>.age` for a fleet one.

      The operator rarely writes an entry here at all: everything
      that needs a secret declares its own (the framework's
      `identity` and `env`, a service module under
      `mkIf cfg.enable`, a `nixhold.repositories` entry), named
      after the thing that consumes it and gone the moment that
      thing is off.
    '';
  };

  # A required secret with no committed ciphertext would otherwise
  # surface as agenix's raw "path does not exist" at build time;
  # fail with the fix spelled out instead. `required = false`
  # secrets are filtered out of `age.secrets` by the platform
  # halves until their ciphertext lands.
  config.assertions = lib.concatLists (
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
        assertion = s.unit == null || (s.homePath == null && !s.sshKey);
        message = ''
          nixhold.secrets.${name}: `unit` makes the secret a
          systemd EnvironmentFile read as root; it cannot also be
          an operator file in $HOME (homePath / sshKey).
        '';
      }
    ]) config.nixhold.secrets
  );
}
