# Tailscale service: Darwin implementation.
#
# nix-darwin's `services.tailscale` runs the open-source tailscaled
# from nixpkgs as a root launchd daemon (`com.tailscale.tailscaled`),
# puts the `tailscale` CLI in `environment.systemPackages`, and writes
# `/etc/resolver/ts.net` pointing at 100.100.100.100 so MagicDNS names
# resolve. `overrideLocalDns` is left at its default `false`: turning
# it on makes 100.100.100.100 the Mac's sole nameserver, so every
# other name on the seat would then depend on the tailnet's DNS
# config.
#
# That open-source variant is not the App Store or standalone client
# (Tailscale KB 1065, "macOS variants"): MagicDNS works and the node
# can advertise itself as an exit node, but there is no GUI, it cannot
# USE an exit node, and it is not MDM-manageable. Login is CLI only,
# so joining the tailnet is a one-time `sudo tailscale up`.
{ config, lib, ... }:
let
  cfg = config.nixhold.services.tailscale;
in
{
  imports = [ ./default.nix ];

  nixhold.services.tailscale.implementation = "darwin";

  services.tailscale.enable = lib.mkIf cfg.enable true;

  assertions = lib.optional (cfg.authKeySecret != null) {
    assertion = false;
    message = "nixhold.services.tailscale.authKeySecret is set on a darwin host, but nix-darwin's tailscale module has no auth-key file. A Mac joins the tailnet with a one-time `sudo tailscale up`.";
  };
}
