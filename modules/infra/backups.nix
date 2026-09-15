# Backup publishing. Reads every `nixhold.services.<n>.backup` that
# names a `dir` — the shipped services' and a fleet-local one's alike
# — and owns the directory the copies land in: group `backups`
# (the one group of this data flow), setgid so every copy inherits
# it, 2750 so nothing outside the group reads a copy; an execute-only
# ACL on the parent for a writer that is not root, since the
# consumer owns that parent and typically closes it to a group the
# writer is not in; a default ACL granting the group read, which is
# what stands in for a umask when the copies are written by the
# daemon itself; and on a named oneshot a 0027 umask, a post-run
# chmod for a copier that preserves the 0600 modes of what it copies,
# and a post-run freshness check. The producer, its timer and the
# transport off the box stay the service's, and so does retention:
# the copies are one overwritten generation, and versions of them are
# the receiver's to keep.
#
# The freshness check is the failure signal: a producer that exits 0
# having written nothing (a source that is not there, a guard that
# swallowed an error) leaves yesterday's copy in place and says
# nothing at all, where a failed unit is a state the box carries
# until someone looks. Anything but a directory written under `dir`
# in the last ten minutes counts; a run long enough to exceed that
# still writes its last file at the end of it.
#
# The directory line lives under `10-<name>`: nixpkgs' vaultwarden
# module creates the same directory under that name, and forcing the
# three fields is what makes the two lines one.
#
# Auto-activates from data; no enable knob. Imported by the NixOS
# baseline, since the data it reads is a service's and not a
# profile's.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  backups = lib.filterAttrs (_: s: (s.backup.dir or null) != null) config.nixhold.services;
  withUnit = lib.filterAttrs (_: s: s.backup.unit != null) backups;

  # Did this run leave anything behind? `-mmin -10` is the producer's
  # own window: the unit has just finished, so the newest file under
  # `dir` is from this run or there was none.
  freshness =
    name: s:
    pkgs.writeShellScript "backup-${name}-fresh" ''
      set -eu
      if [ -z "$(${pkgs.findutils}/bin/find ${s.backup.dir} -mindepth 1 ! -type d -mmin -10 -print -quit)" ]; then
        echo "${s.backup.unit}: nothing was written under ${s.backup.dir} — the run produced no copy" >&2
        exit 1
      fi
    '';
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
      name: s:
      lib.nameValuePair s.backup.unit {
        serviceConfig = {
          # Forced: the hardening set the unit starts from says 0077,
          # and the copies' mode is decided here, not in the producer.
          UMask = lib.mkForce "0027";
          # The exception the chmod below needs, on the one unit that
          # runs it: the tree is setgid `backups`, a symbolic chmod
          # preserves that bit, and `RestrictSUIDSGID` answers any
          # chmod carrying it with EPERM — bit already there or not.
          RestrictSUIDSGID = lib.mkForce false;
          ExecStartPost = [
            # Symbolic, so the directory's setgid bit stays. Modes
            # only: the freshness check after it reads mtimes.
            "${pkgs.coreutils}/bin/chmod -R u=rwX,g=rX,o= ${s.backup.dir}"
            (freshness name s)
          ];
        };
      }
    ) withUnit;
  };
}
