# CLI-managed: `nixhold host add` / `nixhold host remove` edit
# this file end-to-end. Hand-edits are fine too, but keep the
# shape stable (the CLI parses it as a Nix attrset).
{ nixhold, ... }:
{
  # What `nixhold host add` writes (and `host install` completes
  # with the install disk):
  #
  # myhost = {
  #   arch = "x86_64-linux";
  #   profile = nixhold.profiles.server;
  #   modules = [ ./hosts/myhost/default.nix ];
  #   disk = "/dev/disk/by-id/…";
  # };
  #
  # An Android device is a host of the third arch family: no disk,
  # its plan applied over adb by `nixhold deploy` (`serial` is what
  # deploy's device picker writes for one reached over USB):
  #
  # living-room = {
  #   arch = "aarch64-android";
  #   profile = nixhold.profiles.kiosk;
  #   modules = [ ./hosts/living-room/default.nix ];
  # };
}
