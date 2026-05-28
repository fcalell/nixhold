# CLI-managed: `nixhold host add` / `nixhold host remove` edit
# this file end-to-end. Hand-edits are fine too, but keep the
# shape stable (the CLI parses it as a Nix attrset).
{ nixhold, ... }:
{
  # Example host (uncomment and adapt once you run
  # `nixhold host add`):
  #
  # myhost = {
  #   arch = "x86_64-linux";
  #   profile = nixhold.profiles.server;
  #   modules = [ ./hosts/myhost.nix ];
  #   networks = [ "tailnet" ];
  # };
}
