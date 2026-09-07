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

    # Decryption identity: THE fleet key, the same file and the same
    # bytes as on every NixOS host, written to /etc/nixhold/fleet.key
    # (root, 0400) by `nixhold host install --repo … --keys …`.
    # agenix decrypts with `age -d -i <path>`, which accepts a native
    # age identity, so the Mac needs no ssh host key of its own to
    # read a secret — which is just as well, since macOS only
    # generates /etc/ssh host keys once sshd has run.
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

    # `unit` is systemd wiring; a Mac has no systemd, so a secret
    # declaring one here would silently deliver nothing. Say so.
    assertions = lib.mapAttrsToList (name: s: {
      assertion = s.unit == null;
      message = ''
        nixhold.secrets.${name}: `unit` wires a systemd
        EnvironmentFile and is NixOS-only; this host is darwin.
      '';
    }) config.nixhold.secrets;
  };
}
