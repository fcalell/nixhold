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
}
