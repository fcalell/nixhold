{ config, lib, ... }:
let
  inherit (lib) mkOption types;

  keysDir = config.nixhold.layout.keysDir;

  # First line of a committed pubkey file, trailing newline trimmed —
  # `authorized_keys` entries must be single-line. Shared with
  # ./known-hosts.nix so the two readers of `keys/hosts/<host>/*.pub`
  # cannot drift apart.
  pubkeyLine = import ../../lib/pubkey-line.nix "nixhold.fleet";

  archEnum = types.enum [
    "x86_64-linux"
    "aarch64-linux"
    "x86_64-darwin"
    "aarch64-darwin"
  ];

  networkSubmodule = types.submodule {
    options = {
      type = mkOption {
        type = types.enum [
          "tailscale"
          "internet"
        ];
        description = ''
          Network kind. `tailscale` networks use MagicDNS;
          `internet` networks use operator-managed DNS + public
          IPs. v1 enumerates these two — additional types land
          alongside the infra modules that consume them.
        '';
      };

      magicDnsSuffix = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          For tailscale networks: the tailnet's MagicDNS suffix
          (visible in `tailscale status`, e.g.
          `tail-abc123.ts.net`). Used to compute
          `derived.address.<host>.<this-network>` as
          `"<host>.<magicDnsSuffix>"`. Without it, tailscale
          addresses resolve to `null`.
        '';
        example = "tail6ac451.ts.net";
      };

      domain = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          For internet networks: the root domain hosts on this
          network expose subdomains under (e.g. `example.com`).
        '';
        example = "example.com";
      };
    };
  };

  hostSubmodule = types.submodule (
    { name, ... }:
    {
      options = {
        arch = mkOption {
          type = archEnum;
          description = "Host arch in standard Nix system-double form.";
          example = "x86_64-linux";
        };

        profile = mkOption {
          type = types.deferredModule;
          description = ''
            The profile attached to this host. A NixOS / Darwin
            module value, referenced as
            `nixhold.profiles.<name>` or a forker-authored
            module. `mkFleet` adds it to the host's imports.
          '';
        };

        modules = mkOption {
          type = types.listOf types.deferredModule;
          default = [ ];
          description = ''
            Operator's per-host modules: the host config file,
            disko import, facter pointer, anything host-specific.
            The framework places no naming or directory
            constraint on these — principle 14 prohibits
            filesystem-based discovery.
          '';
        };

        networks = mkOption {
          type = types.listOf types.str;
          default = [ "tailnet" ];
          description = ''
            Networks this host is a member of. Each entry must be
            a key in `mkFleet`'s `networks` arg. Default
            `[ "tailnet" ]`; add `"public"` on gateway hosts.
          '';
        };

        publicIp = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = ''
            Stable public IPv4 for this host, if any. Set on the
            single gateway / VPS in the fleet. v1 lint asserts at
            most one host has a non-null `publicIp`.
          '';
          example = "203.0.113.42";
        };

        publicFqdn = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = ''
            DNS name for this host's `publicIp` when an A record
            exists. Operator-declared (DNS is operator-managed in
            v1). Consumed by
            `derived.address.<host>.<internet-typed-net>`.
          '';
          example = "homelab.example.com";
        };

        loginPubkey = mkOption {
          type = types.nullOr types.str;
          defaultText = lib.literalMD "first line of `keys/hosts/<host>/identity.pub` when committed, else `null`";
          description = ''
            The operator's SSH login pubkey originating from this
            host. Defaults to the committed
            `keys/hosts/<host>/identity.pub` (written by the CLI
            when it bootstraps/rekeys the host's `sshIdentity`
            secret); an explicit value overrides. Aggregated across
            hosts into `derived.operatorAuthorizedKeys` and
            authorized on every host's operator account. `null`
            until the host's key exists.
          '';
        };
      };

      config = {
        loginPubkey =
          let
            p = keysDir + "/hosts/${name}/identity.pub";
          in
          lib.mkDefault (if builtins.pathExists p then pubkeyLine p else null);
      };
    }
  );
in
{
  options.nixhold.fleet = {
    hosts = mkOption {
      type = types.attrsOf hostSubmodule;
      default = { };
      description = ''
        Per-host topology. Strict submodule — no freeformType.
        Forkers needing per-host custom data declare their own
        option in their fork (`options.myorg.<x>`).
      '';
    };

    network = mkOption {
      type = types.attrsOf networkSubmodule;
      default = { };
      description = ''
        Per-network definitions. Network *names* are
        forker-chosen (`tailnet`, `public`); network *types*
        are the framework enum (`tailscale`, `internet`).
      '';
    };

    selfName = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        This host's own key in `nixhold.fleet.hosts` — its fleet
        identity, set by `mkFleet` from the attribute name in the
        `hosts` argument. Everything the framework derives per
        host (its entry in `hosts`, its secrets tree, its
        committed host pubkey) keys off this, NOT off
        `config.networking.hostName`: the OS hostname is merely
        `mkDefault`ed to it, and a host may legitimately carry a
        different one (an MDM-managed name, a rename) without its
        ciphertexts or recipients moving. `null` only when the
        namespace is evaluated outside `mkFleet` — the framework's
        own checks — where no single host owns it.
      '';
    };

    derived = {
      self = mkOption {
        type = types.nullOr types.raw;
        readOnly = true;
        description = ''
          This host's own entry in `nixhold.fleet.hosts`,
          resolved by `nixhold.fleet.selfName`. The single
          canonicalization point for fleet-key → host-entry
          mapping. `null` if this host isn't a key in `hosts`
          (e.g. during framework checks against a synthetic
          fixture). Typed `raw` to pass the already-processed
          host submodule value through unchanged.
        '';
      };

      publicHosts = mkOption {
        type = types.listOf types.str;
        readOnly = true;
        description = ''
          Hosts with a non-null `publicIp`. v1 lint asserts
          `length ≤ 1` (single-gateway invariant). The list
          shape future-proofs against multi-gateway designs
          without renaming.
        '';
      };

      hostsByNetwork = mkOption {
        type = types.attrsOf (types.listOf types.str);
        readOnly = true;
        description = ''
          For each declared network, the list of hosts that
          have it in their `networks` field. Consumers walk
          this for cross-host wiring without re-deriving the
          membership predicate.
        '';
      };

      address = mkOption {
        type = types.attrsOf (types.attrsOf (types.nullOr types.str));
        readOnly = true;
        description = ''
          Per-host, per-network address.
          `derived.address.<host>.<network>` returns the FQDN
          (preferred) or IP for reaching `<host>` over
          `<network>`, or `null` if the pair has no resolvable
          address. Null entries are visible (not pruned) so
          consumers can pattern-match and produce useful error
          messages.

          There is no `addressOf` shortcut. Consumers spell out
          which network they're resolving on — making the
          topology choice explicit eliminates the
          "first shared network" guess.
        '';
      };

      operatorAuthorizedKeys = mkOption {
        type = types.listOf types.str;
        readOnly = true;
        description = ''
          Union of every host's non-null `loginPubkey` — the
          operator's SSH login keys. Authorized on every host's
          operator account (`users.users.<operator>`); root login
          stays closed.
        '';
      };
    };
  };
}
