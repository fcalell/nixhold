# `nixhold.checks` — darwin rendering: one launchd daemon per check
# (ARCHITECTURE "Provisioning": Checks are units too).
#
# A daemon rather than an agent, because a check is the machine's and
# not a session's: it runs whether or not the operator is logged in,
# under the uid the declaration names. launchd has no start limit, so
# a failing check is retried every 30 s for as long as the machine is
# up, and no hardening set: there is nothing on this platform to
# merge. `after` has no launchd equivalent either, so on a Mac the
# retry is the whole ordering.
{ config, lib, ... }:
let
  provisioning = import ../../lib/provisioning.nix { inherit lib; };
in
{
  config.launchd.daemons = lib.mapAttrs' (
    name: check:
    lib.nameValuePair "nixhold-check-${name}" (
      lib.mkMerge [
        (provisioning {
          description = "nixhold check: ${name}";
          script = check.program;
          after = check.after;
          scope = "system";
        }).launchd
        { serviceConfig.UserName = check.user; }
      ]
    )
  ) config.nixhold.checks;
}
