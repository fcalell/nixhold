# `nixhold.checks` run rather than evaluated (ARCHITECTURE
# "Provisioning": Checks are units too). The fixture builds the units;
# this boots a host that declares one check that passes and one that
# fails, and reads them exactly as `nixhold status` and `nixhold
# deploy` do.
#
# The module list is the two halves of the option, not a fleet: a
# check's unit reads nothing the baseline provides.
{ pkgs }:
pkgs.testers.runNixOSTest {
  name = "nixhold-checks";

  nodes.machine = {
    imports = [
      ../../modules/checks
      ../../modules/checks/nixos.nix
    ];

    nixhold.checks = {
      pass = {
        after = [ "multi-user.target" ];
        script = "true";
      };
      fail = {
        after = [ "multi-user.target" ];
        script = "false";
      };
    };
  };

  testScript = ''
    machine.wait_for_unit("multi-user.target")

    # A check that passes runs once and is done: exit 0, and `Restart
    # = on-failure` never restarts it. Nothing keeps it loaded as
    # active, which is why the verbs read "inactive" as the pass.
    machine.wait_until_succeeds(
        "systemctl show -p Result --value nixhold-check-pass.service | grep -qx success"
    )
    machine.succeed(
        "systemctl show -p ExecMainStatus --value nixhold-check-pass.service | grep -qx 0"
    )
    machine.fail("systemctl is-active --quiet nixhold-check-pass.service")

    # A check that fails is retried on the same shape every
    # provisioning unit takes: between attempts it is
    # `activating (auto-restart)`, and once the start limit is spent
    # it is `failed`. Both are what the verbs report.
    machine.wait_until_succeeds(
        "systemctl show -p SubState --value nixhold-check-fail.service"
        " | grep -qE '^(auto-restart|failed)$'"
    )

    # One glob lists both, which is the read the CLI makes.
    units = machine.succeed(
        "systemctl list-units --all --plain --no-legend 'nixhold-check-*'"
    )
    assert "nixhold-check-pass.service" in units, units
    assert "nixhold-check-fail.service" in units, units

    # And the kick `nixhold deploy` runs after activation re-runs a
    # check that already passed: no done marker, so every deploy
    # re-asserts what the fleet declares.
    before = machine.succeed(
        "systemctl show -p InvocationID --value nixhold-check-pass.service"
    ).strip()
    machine.execute(
        "systemctl reset-failed 'nixhold-check-*'; systemctl start --all 'nixhold-check-*'"
    )
    machine.wait_until_succeeds(
        "test \"$(systemctl show -p InvocationID --value nixhold-check-pass.service)\""
        f" != {before}"
    )
  '';
}
