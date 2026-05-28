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
    age.secrets = lib.mapAttrs (_: s: {
      inherit (s) file;
      owner = s.resolvedOwner;
      mode = s.resolvedMode;
    }) config.nixhold.secrets;
  };
}
