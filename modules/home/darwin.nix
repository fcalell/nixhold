# Darwin half of the home-manager wiring. Mirrors nixos.nix
# against `darwinModules.home-manager`.
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

  # Same bootstrapped-ness filter as the secrets platform half: a
  # `required = false` secret with no ciphertext yet has no
  # `age.secrets` entry, so emitting its symlink would dangle at eval.
  symlinkSecrets = lib.filterAttrs (
    _: s: s.homePath != null && (s.required || builtins.pathExists s.file)
  ) config.nixhold.secrets;
  sshSymlinkSecrets = lib.filterAttrs (
    name: s: lib.hasPrefix "ssh-" name && s.resolvedOwner == username
  ) symlinkSecrets;

  # Cross-host ssh client config: a matchBlock per fleet peer,
  # routed over the first network the peer shares with this host.
  fleet = config.nixhold.fleet;
  selfNets = if fleet.derived.self == null then [ ] else fleet.derived.self.networks;
  peerAddr =
    peerName: peer:
    let
      shared = lib.filter (n: lib.elem n selfNets) peer.networks;
      addrs = lib.filter (a: a != null) (
        map (n: fleet.derived.address.${peerName}.${n} or null) shared
      );
    in
    if addrs == [ ] then null else lib.head addrs;
  # The operator's outbound key, by the ssh-personal convention.
  personalKey =
    let
      s = config.nixhold.secrets.ssh-personal or null;
    in
    if s != null && s.homePath != null then "~/${s.homePath}" else null;
  sshSettings = lib.mapAttrs (
    _: addr:
    {
      HostName = addr;
      User = username;
    }
    // lib.optionalAttrs (personalKey != null) {
      IdentityFile = personalKey;
      IdentitiesOnly = true;
    }
  ) (
    lib.filterAttrs (_: a: a != null) (
      lib.mapAttrs peerAddr (lib.filterAttrs (n: _: n != config.networking.hostName) fleet.hosts)
    )
  );
in
{
  imports = [ inputs.nixhold.inputs.home-manager.darwinModules.home-manager ];

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

        # home-manager requires a stateVersion. nix-darwin's
        # `system.stateVersion` is an integer on a different scale, so
        # (unlike the NixOS half) we can't tie HM's release-string
        # stateVersion to it — default to the framework baseline.
        # mkDefault leaves a per-host HM module free to override.
        home.stateVersion = lib.mkDefault "24.11";

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
              ${pkgs.openssh}/bin/ssh-keygen -y -f "$src" > "$dst" 2>/dev/null || true
              chmod 0644 "$dst" 2>/dev/null || true
            else
              echo "nixhold: ${name} not decrypted yet; skipping $dst (agenix decrypts asynchronously on darwin — re-run activation once /run/agenix is populated)" >&2
            fi
          '';
        }) sshSymlinkSecrets;
      };
    };
  };
}
