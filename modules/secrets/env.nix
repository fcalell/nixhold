# The operator's global environment: one fleet-wide ciphertext of
# KEY=value lines, sourced into every login shell by the platform
# halves (nixos.nix, darwin.nix). Declared by the platforms that have
# a shell to source it into, so an Android host never lists it. The
# escape hatch for values that are not NixOS-shaped (API tokens read
# by ad-hoc tooling). Not required: a fleet that never provisions it
# never notices it.
{ ... }:
{
  nixhold.secrets.env = {
    scope = "fleet";
    required = false;
    category = "framework";
    owner = "user";
    description = "global env (KEY=value lines) sourced into every shell of the operator";
    template = ''
      # KEY=value, one per line. Sourced by every shell.
    '';
  };
}
