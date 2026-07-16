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

    # Decryption identity, pinned explicitly: agenix's NixOS default
    # derives it from `services.openssh.hostKeys` only when openssh is
    # enabled — a host without the openssh preset would silently have
    # no identities. This is the key `nixhold host install` stages and
    # whose pubkey is committed as keys/hosts/<host>/host.pub.
    age.identityPaths = lib.mkDefault [ "/etc/ssh/ssh_host_ed25519_key" ];
  };
}
