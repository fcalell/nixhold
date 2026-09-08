# Rule: a roster `disk` is a /dev/disk/by-id path.
#
# `hosts.<host>.disk` is what the framework renders its disko shape
# from, so it is the path the installed host mounts its root from on
# every boot. An enumeration-order name (`/dev/sda`) is assigned in
# probe order: another disk in the machine, or a USB stick left in at
# boot, moves it, and the host then formats or mounts the wrong device.
# A `/dev/disk/by-id/` alias is minted from the model and serial and
# names the same physical disk forever.
#
# A hand-written roster legitimately holds `/dev/sda` until the host is
# first installed, so this warns in dev and errors under --strict (the
# CI gate). A host with no `disk` declares its own `disko.devices` and
# is not reported.

strict="${NIXHOLD_LINT_STRICT:-0}"
worst=0
problems=0

report() {
  problems=$((problems + 1))
  if [ "$strict" = "1" ]; then
    echo "VIOLATION: $1"
    worst=3
  else
    echo "WARNING: $1"
  fi
}

while IFS= read -r line; do
  h="${line%% *}"
  [ -n "$h" ] || continue
  disk="$(nh_host_field "$h" disk)"
  [ -n "$disk" ] || continue
  case "$disk" in
    /dev/disk/by-id/*) continue ;;
  esac
  report "$h — disk = \"$disk\" is an enumeration-order name, which moves when another disk or a USB stick is present at boot ('nixhold host install $h' resolves it on the target and records the stable /dev/disk/by-id path, or pass --disk <by-id>)"
done < <(nh_hosts nixos)

if [ "$problems" -eq 0 ]; then
  echo "OK: every roster disk is a /dev/disk/by-id path"
fi
exit "$worst"
