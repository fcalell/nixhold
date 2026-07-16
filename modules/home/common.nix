# Platform-independent home-manager wiring, imported by both
# nixos.nix and darwin.nix (which contribute only the HM platform
# module import and the stateVersion strategy). Emits HM symlinks
# for secrets with `homePath`, `.pub` derivation for `sshKey`
# secrets, and the fleet-peer ssh client config.
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
  # The operator's outbound key: the (at most one, per assertion)
  # secret declaring `sshIdentity = true`.
  identityKey =
    let
      matches = lib.attrValues (lib.filterAttrs (_: s: s.sshIdentity) config.nixhold.secrets);
    in
    if matches == [ ] then null else "~/${(lib.head matches).homePath}";
  sshSettings =
    lib.mapAttrs
      (
        _: addr:
        {
          HostName = addr;
          User = username;
        }
        // lib.optionalAttrs (identityKey != null) {
          IdentityFile = identityKey;
          IdentitiesOnly = true;
        }
      )
      (
        lib.filterAttrs (_: a: a != null) (
          lib.mapAttrs peerAddr (lib.filterAttrs (n: _: n != config.networking.hostName) fleet.hosts)
        )
      );
in
{
  config = {
    home-manager = {
      useGlobalPkgs = lib.mkDefault true;
      useUserPackages = lib.mkDefault true;
      extraSpecialArgs = {
        inherit inputs identity;
      };

      users.${username} = hmArgs: {
        imports = config.nixhold.home.extraModules;

        programs.ssh = {
          enable = lib.mkDefault true;
          settings = sshSettings;
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
