# Darwin activation half of the secrets module. Mirrors
# nixos.nix; agenix ships a parallel darwin module that wires
# `age.secrets.<name>` into a launchd-driven activation phase.
{
  config,
  lib,
  inputs,
  ...
}:
{
  imports = [ inputs.nixhold.inputs.agenix.darwinModules.default ];

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

    # Decryption identity, pinned explicitly (agenix's darwin default
    # is the same pair; pinning makes the contract visible). macOS
    # only generates /etc/ssh host keys once sshd has run — the
    # bootstrap runbook's `ssh-keygen -A` step — and the committed
    # keys/hosts/<host>/host.pub must be this key's pubkey.
    age.identityPaths = lib.mkDefault [ "/etc/ssh/ssh_host_ed25519_key" ];
  };
}
