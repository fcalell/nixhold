# Backup publishing. Reads every `nixhold.services.<n>.backup` that
# names a `dir` — the shipped services' and a fleet-local one's alike
# — and owns the directory the copies land in: group `backups`
# (the one group of this data flow), setgid so every copy inherits
# it, 2750 so nothing outside the group reads a copy; an execute-only
# ACL on the parent for a writer that is not root, since the
# consumer owns that parent and typically closes it to a group the
# writer is not in; a default ACL granting the group read, which is
# what stands in for a umask when the copies are written by the
# daemon itself; and on a named oneshot a 0027 umask plus a post-run
# chmod, for a copier that preserves the 0600 modes of what it
# copies. The producer, its timer and the transport off the box stay
# the service's.
#
# The directory line lives under `10-<name>`: nixpkgs' vaultwarden
# module creates the same directory under that name, and forcing the
# three fields is what makes the two lines one.
#
# Auto-activates from data; no enable knob.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  backups = lib.filterAttrs (_: s: (s.backup.dir or null) != null) config.nixhold.services;
  withUnit = lib.filterAttrs (_: s: s.backup.unit != null) backups;
in
{
  config = lib.mkIf (backups != { }) {
    users.groups.backups = { };

    systemd.tmpfiles.settings = lib.mapAttrs' (
      name: s:
      lib.nameValuePair "10-${name}" (
        {
          ${s.backup.dir} = {
            d = {
              user = lib.mkForce s.backup.user;
              group = lib.mkForce "backups";
              mode = lib.mkForce "2750";
            };
            "a+".argument = "d:g:backups:r";
          };
        }
        # tmpfiles lets a `+` type share a path with another file's
        # `d` line and runs the two in file order, so the parent's own
        # rule must sort before `10-<name>`. The parent must exist:
        # this line never creates it.
        // lib.optionalAttrs (s.backup.user != "root") {
          ${dirOf s.backup.dir}."a+".argument = "u:${s.backup.user}:x";
        }
      )
    ) backups;

    systemd.services = lib.mapAttrs' (
      _: s:
      lib.nameValuePair s.backup.unit {
        serviceConfig = {
          # Forced: the hardening set the unit starts from says 0077,
          # and the copies' mode is decided here, not in the producer.
          UMask = lib.mkForce "0027";
          # Symbolic, so the directory's setgid bit stays.
          ExecStartPost = "${pkgs.coreutils}/bin/chmod -R u=rwX,g=rX,o= ${s.backup.dir}";
        };
      }
    ) withUnit;
  };
}
