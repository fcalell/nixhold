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
    age.secrets = lib.mapAttrs (_: s: {
      inherit (s) file;
      owner = s.resolvedOwner;
      mode = s.resolvedMode;
    }) config.nixhold.secrets;
  };
}
