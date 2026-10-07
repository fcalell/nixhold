# The pressure floor run rather than evaluated (ARCHITECTURE
# "Pressure"): the recovery path sits in the protected slice, and a
# unit that stalls system.slice is killed by systemd-oomd while sshd
# and tailscaled keep running.
#
# The stall is a unit allocating past its own MemoryHigh, the way
# systemd's own oomd test builds pressure: every allocation is
# throttled, so the slice's full pressure climbs past its limit while
# the rest of the machine has memory to spare.
{ pkgs }:
pkgs.testers.runNixOSTest {
  name = "nixhold-pressure";

  nodes.machine = {
    imports = [ ../../modules/pressure ];

    services.openssh.enable = true;
    services.tailscale.enable = true;
    zramSwap.enable = true;
    virtualisation.memorySize = 1024;
  };

  testScript = ''
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("sshd.service")
    machine.wait_for_unit("tailscaled.service")

    # The recovery path, in the top-level slice that holds its floor.
    for unit in ["sshd.service", "tailscaled.service"]:
        cgroup = machine.succeed(f"systemctl show -p ControlGroup --value {unit}").strip()
        assert cgroup == f"/core.slice/{unit}", cgroup
    machine.succeed("grep -qx 268435456 /sys/fs/cgroup/core.slice/memory.min")

    # oomd watches the slices below the root for pressure and the root
    # for swap.
    machine.wait_for_unit("systemd-oomd.service")
    watched = machine.succeed("oomctl dump")
    assert "/system.slice" in watched, watched
    assert "/user.slice" in watched, watched

    machine.succeed(
        "systemd-run --unit=hog -p MemoryHigh=64M"
        " ${pkgs.stress-ng}/bin/stress-ng --vm 1 --vm-bytes 384M --vm-keep --timeout 600"
    )
    machine.wait_until_succeeds(
        "journalctl -u systemd-oomd --no-pager | grep -q 'system.slice/hog.service'",
        timeout=300,
    )
    machine.fail("systemctl is-active --quiet hog.service")

    machine.succeed("systemctl is-active --quiet sshd.service")
    machine.succeed("systemctl is-active --quiet tailscaled.service")
  '';
}
