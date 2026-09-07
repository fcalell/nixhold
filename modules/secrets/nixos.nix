# NixOS activation half of the secrets module. Imports agenix's
# NixOS module and projects `nixhold.secrets.<name>` onto
# `age.secrets.<name>`. Operator never touches `age.*` directly.
{
  config,
  lib,
  inputs,
  ...
}:
{
  imports = [ inputs.nixhold.inputs.agenix.nixosModules.default ];

  config = {
    # Inactive secrets (`required = false`, ciphertext not yet
    # bootstrapped) are left out — agenix would otherwise fail the
    # build importing the missing .age path. Required-but-missing is
    # caught by the assertion in ./default.nix.
    age.secrets = lib.mapAttrs (_: s: {
      inherit (s) file;
      owner = s.resolvedOwner;
      mode = s.resolvedMode;
    }) (lib.filterAttrs (_: s: s.active) config.nixhold.secrets);

    # Decryption identity: THE fleet key, the same one on every host,
    # staged at /etc/nixhold/fleet.key (root, 0400) by `nixhold host
    # install` and re-installed by `nixhold deploy`. It is a native
    # age identity rather than an ssh key — agenix decrypts with
    # `age -d -i <path>`, which accepts either. Pinned explicitly: the
    # agenix default derives identities from
    # `services.openssh.hostKeys`, which is the pre-fleet-key model
    # and would leave a host holding a key that is no recipient of
    # anything. The host's own ssh key is ordinary now: pinning data
    # for known_hosts, never a decryption identity.
    age.identityPaths = lib.mkDefault [ "/etc/nixhold/fleet.key" ];

    # The operator's global environment, sourced by every shell.
    # `environment.extraInit` lands in the system-wide
    # set-environment script, which every login shell sources — the
    # file itself is 0600 and owned by the operator, so the
    # readability test is the access control: any other account
    # sources nothing. `set -a` exports what the file assigns,
    # nothing else.
    environment.extraInit = lib.mkIf config.nixhold.secrets.env.active ''
      if [ -r ${config.age.secrets.env.path} ]; then
        set -a
        . ${config.age.secrets.env.path}
        set +a
      fi
    '';

    # `unit` secrets: the declared unit reads the decrypted file as
    # its EnvironmentFile. A list, so two secrets may feed one unit
    # (unitOption merges lists by concatenation) and so an operator's
    # own EnvironmentFile is added to, never replaced.
    systemd.services = lib.mkMerge (
      lib.mapAttrsToList (name: s: {
        ${s.unit}.serviceConfig.EnvironmentFile = [ config.age.secrets.${name}.path ];
      }) (lib.filterAttrs (_: s: s.unit != null && s.active) config.nixhold.secrets)
    );
  };
}
