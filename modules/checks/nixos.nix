# `nixhold.checks` — NixOS rendering: one system service per check
# (ARCHITECTURE "Provisioning": Checks are units too).
#
# The unit shape is lib/provisioning.nix's, the same retry a checkout
# unit takes, plus the framework hardening set every unit the
# framework or the fleet defines starts from ("One hardening set"): a
# check reads evidence, so a read-only system, no capabilities and no
# home is what it needs. A check whose evidence sits outside that runs
# as the uid that owns it (`user`), or names its exception on the
# rendered unit: `systemd.services.nixhold-check-<name>.serviceConfig`
# is a plain NixOS option like any other.
{ config, lib, ... }:
let
  hardening = import ../../lib/hardening.nix;
  provisioning = import ../../lib/provisioning.nix { inherit lib; };
in
{
  config.systemd.services = lib.mapAttrs' (
    name: check:
    lib.nameValuePair "nixhold-check-${name}" (
      lib.mkMerge [
        (provisioning {
          description = "nixhold check: ${name}";
          script = check.program;
          after = check.after;
          scope = "system";
        }).systemd
        {
          serviceConfig = hardening // {
            User = check.user;
          };
        }
      ]
    )
  ) config.nixhold.checks;
}
