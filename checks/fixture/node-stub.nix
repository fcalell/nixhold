# fixture-node — the fixture's genuinely tailnet-only host, and the
# only place the framework's default SSH posture is actually reachable.
#
# fixture-server and fixture-gateway are both members of the `public`
# internet-typed network, so both take the internet branch of
# modules/services/openssh/nixos.nix: sshd's port opened fleet-wide and
# fail2ban on. This host is on `tailnet` alone, which is the shape the
# framework optimises for — the operator reaches it over the tailnet
# and nothing else should find its sshd — so it takes the other branch,
# and the assertions below are what keep that branch from silently
# regressing into "open to whatever LAN the box is plugged into".
#
# It serves no endpoint on purpose: the caddy/firewall endpoint
# branches are covered by the other two hosts, and an endpoint here
# would open 443 and blur what these assertions are about.
{ config, lib, ... }:
let
  # The same interface name modules/infra/firewall.nix and the openssh
  # module scope their rules to.
  iface = config.services.tailscale.interfaceName;
  ifacePorts =
    (config.networking.firewall.interfaces.${iface} or { allowedTCPPorts = [ ]; }).allowedTCPPorts;
in
{
  # No machine ever ran `host install` for a fixture host, so there is
  # no report to point at: opt out of the facter guard.
  nixhold.hardware.facterReport = null;

  assertions = [
    {
      assertion = !config.services.openssh.openFirewall;
      message = "fixture-node: a host on no internet-typed network must not open sshd fleet-wide (services.openssh.openFirewall is true)";
    }
    {
      assertion = !(lib.elem 22 config.networking.firewall.allowedTCPPorts);
      message = "fixture-node: port 22 is open on every interface; on a tailnet-only host it belongs to ${iface} alone";
    }
    {
      assertion = lib.elem 22 ifacePorts;
      message = "fixture-node: port 22 is not opened on ${iface} — the host would be unreachable over the tailnet the fleet deploys across";
    }
    {
      assertion = !config.services.fail2ban.enable;
      message = "fixture-node: fail2ban is enabled on a host with no internet-typed network — there is nothing reaching sshd for it to ban";
    }
  ];
}
