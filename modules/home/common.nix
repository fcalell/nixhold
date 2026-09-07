# Platform-independent home-manager wiring, imported by both
# nixos.nix and darwin.nix (which contribute only the HM platform
# module import and the stateVersion strategy). Emits HM symlinks
# for secrets with `homePath`, `.pub` derivation for `sshKey`
# secrets, the fleet-peer ssh client config, and the git author.
{
  config,
  lib,
  pkgs,
  inputs,
  identity,
  ...
}:
let
  username = config.nixhold.identity.username;

  # Same bootstrapped-ness filter as the secrets platform half: an
  # inactive secret has no `age.secrets` entry, so emitting its
  # symlink would dangle at eval.
  symlinkSecrets = lib.filterAttrs (_: s: s.homePath != null && s.active) config.nixhold.secrets;
  # `.pub` derivation is driven by the explicit sshKey option —
  # never by the secret's name.
  sshKeySecrets = lib.filterAttrs (_: s: s.sshKey) symlinkSecrets;

  # Cross-host ssh client config: a matchBlock per fleet peer,
  # routed over the first network the peer shares with this host.
  fleet = config.nixhold.fleet;
  selfNets = if fleet.derived.self == null then [ ] else fleet.derived.self.networks;
  peerAddr =
    peerName: peer:
    let
      shared = lib.filter (n: lib.elem n selfNets) peer.networks;
      addrs = lib.filter (a: a != null) (map (n: fleet.derived.address.${peerName}.${n} or null) shared);
    in
    if addrs == [ ] then null else lib.head addrs;
  # The fleet's one outbound SSH key: the framework-declared
  # `identity` secret (below). It is a framework declaration, so the
  # framework may know its name — the rule that names never carry
  # behaviour is about operator-chosen names. `null` until the
  # ciphertext is provisioned, so a fresh host still evaluates.
  identitySecret = config.nixhold.secrets.identity;
  identityKey = if identitySecret.active then "~/${identitySecret.homePath}" else null;
  sshSettings =
    lib.mapAttrs
      (
        peerName: addr:
        {
          HostName = addr;
          User = username;
        }
        # Name the fleet's own key whenever the fleet has one — it is
        # the key a no-token fleet authorizes (the CLI seeds
        # `keys/login.pub` from it), so leaving it unnamed would make
        # `ssh <peer>` depend on ssh's default filenames. But never
        # `IdentitiesOnly`: the operator's other login keys are
        # hardware-token resident keys with no file to name, offered
        # by the agent, and pinning this one to the exclusion of the
        # rest is exactly how a token fleet locks itself out. Forge
        # blocks keep both — a forge authenticates the fleet's
        # OUTBOUND key alone (modules/repositories/default.nix).
        // lib.optionalAttrs (identityKey != null) {
          IdentityFile = identityKey;
        }
        # A peer whose host key is committed is pinned system-wide by
        # modules/fleet/known-hosts.nix, so there is nothing left to
        # trust on first use: an unknown or changed key is a failure,
        # not a prompt. Peers without a committed key (added but not
        # yet keyed) keep ssh's default accept-on-first-use.
        // lib.optionalAttrs (fleet.hostPubkey.${peerName} or null != null) {
          StrictHostKeyChecking = "yes";
        }
      )
      (
        lib.filterAttrs (_: a: a != null) (
          # Peers = every fleet host but THIS one, keyed off the fleet
          # name (`selfName`) rather than the OS hostname: a darwin
          # host's MDM name routinely differs from its fleet key, and
          # matching on the wrong one leaves the host with an ssh
          # block pointing at itself.
          lib.mapAttrs peerAddr (lib.filterAttrs (n: _: n != fleet.selfName) fleet.hosts)
        )
      );
  # The `Host *` block: what every connection gets before any named
  # block narrows it. home-manager is retiring its own implicit
  # defaults, so the framework declares them (`enableDefaultConfig =
  # false` below) rather than inheriting a set that is scheduled to
  # disappear. These mirror what home-manager had, with
  # `AddKeysToAgent` flipped on so a key is typed for once per boot.
  #
  # `IdentitiesOnly` is deliberately absent, and this is the block
  # where its absence is decided: set here it would apply to the peer
  # blocks too, which name `~/.ssh/identity` and nothing else, and a
  # resident FIDO2 login key lives in the agent with no file to name
  # (see "Login keys"). A fleet that authorizes a token would then be
  # a fleet whose token cannot log in. The cost is the other half of
  # the trade: without it ssh offers every agent-held key to every
  # host it talks to, so an unrelated server learns which pubkeys the
  # operator holds. Forge blocks pin themselves anyway
  # (modules/repositories/default.nix), so this widens fleet peers and
  # ad-hoc hosts only.
  #
  # Per-directive mkDefault: a fleet overrides one line without
  # restating the block.
  clientDefaults = lib.mapAttrs (_: lib.mkDefault) {
    AddKeysToAgent = "yes";
    ForwardAgent = false;
    Compression = false;
    ServerAliveInterval = 0;
    ServerAliveCountMax = 3;
    HashKnownHosts = false;
    UserKnownHostsFile = "~/.ssh/known_hosts";
    ControlMaster = "no";
    ControlPath = "~/.ssh/master-%r@%n:%p";
    ControlPersist = "no";
  };
in
{
  config = {
    # Framework declaration, every host, both platforms: THE
    # outbound SSH key of the fleet — fleet peers and every git
    # forge, authentication and commit signing. Fleet-scoped: one
    # key for every host, so it is registered on each forge once and
    # revoking it revokes the fleet (which is what a solo operator
    # wants — a compromised machine means every key it held is
    # burned anyway, and per-host keys would put a manual forge step
    # in front of every new machine). Not required: a host evaluates
    # (and installs) before the fleet has one.
    nixhold.secrets.identity = {
      scope = "fleet";
      sshKey = true;
      required = false;
      category = "framework";
      description = "the fleet's outbound SSH key (fleet peers, git forges, commit signing)";
    };

    home-manager = {
      useGlobalPkgs = lib.mkDefault true;
      useUserPackages = lib.mkDefault true;
      extraSpecialArgs = {
        inherit inputs identity;
      };

      users.${username} = hmArgs: {
        imports = [ ./claude-code-native.nix ] ++ config.nixhold.home.extraModules;

        programs.ssh = {
          enable = lib.mkDefault true;
          # Opt out of home-manager's implicit `Host *` defaults: the
          # framework states the ones it wants, above.
          enableDefaultConfig = false;
          settings = sshSettings // {
            "*" = clientDefaults;
          };
        };

        # Git author from identity, only where git is enabled: the
        # username (commit attribution stays stable across fleets and
        # forges) and the email. Commits are signed with the same key
        # that reaches the forge — one key for the fleet, registered
        # once as both an authentication and a signing key.
        programs.git = lib.mkIf hmArgs.config.programs.git.enable {
          settings.user = {
            name = lib.mkDefault username;
            email = lib.mkDefault identity.email;
          };
          signing = lib.mkIf (identityKey != null) {
            format = lib.mkDefault "ssh";
            key = lib.mkDefault "${identityKey}.pub";
            signByDefault = lib.mkDefault true;
          };
        };

        home.file = lib.mapAttrs' (name: s: {
          name = s.homePath;
          value.source = hmArgs.config.lib.file.mkOutOfStoreSymlink hmArgs.osConfig.age.secrets.${name}.path;
        }) symlinkSecrets;

        home.activation = lib.mapAttrs' (name: s: {
          name = "nixhold-ssh-pub-${name}";
          value = hmArgs.lib.hm.dag.entryAfter [ "writeBoundary" ] ''
            src="${hmArgs.osConfig.age.secrets.${name}.path}"
            dst="$HOME/${s.homePath}.pub"
            if [ -r "$src" ]; then
              if ${pkgs.openssh}/bin/ssh-keygen -y -f "$src" > "$dst.tmp" 2>/dev/null; then
                mv "$dst.tmp" "$dst"
                chmod 0644 "$dst" 2>/dev/null || true
              else
                rm -f "$dst.tmp"
                echo "nixhold: ERROR deriving $dst — secret '${name}' is readable but is not a valid SSH private key (sshKey = true on a non-key secret?)" >&2
              fi
            else
              echo "nixhold: ${name} not decrypted yet; skipping $dst (agenix decrypts asynchronously on darwin — re-run activation once /run/agenix is populated)" >&2
            fi
          '';
        }) sshKeySecrets;
      };
    };
  };
}
