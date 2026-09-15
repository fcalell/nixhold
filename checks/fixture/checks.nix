# Fixture coverage for `nixhold.checks` (ARCHITECTURE "Provisioning":
# Checks are units too). Imported by fixture-server and fixture-mac,
# so both platform halves render the same two declarations: a check
# written as shell source and a check that names a program.
#
# What the unit DOES when it runs is checks/vm/checks.nix; what it
# looks like is here.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
  hardening = import ../../lib/hardening.nix;
  checks = config.nixhold.checks;
  # The `path` half of `script`: a program the fleet already has is
  # run as it is, never re-wrapped.
  program = pkgs.writeShellScript "fixture-check-program" "true";
in
{
  nixhold.checks = {
    fixture = {
      script = ''
        test -e /etc/os-release
      '';
      after = [ "multi-user.target" ];
    };
    fixture-program = {
      script = program;
      user = "nobody";
    };
  };

  assertions = [
    {
      assertion = lib.hasPrefix builtins.storeDir checks.fixture.program;
      message = "fixture: a check written as shell source must reach the unit as a program in the store, got ${checks.fixture.program}";
    }
    {
      assertion = checks.fixture-program.program == "${program}";
      message = "fixture: a check whose script IS a program must run that program, got ${checks.fixture-program.program}";
    }
    {
      # The retry shape lib/provisioning.nix renders, the hardening set
      # every framework unit takes, and no done marker: a check is
      # re-run by every deploy.
      assertion =
        isDarwin
        || (
          let
            u = config.systemd.services.nixhold-check-fixture;
          in
          u.serviceConfig.Type == "exec"
          && u.serviceConfig.ExecStart == checks.fixture.program
          && u.serviceConfig.Restart == "on-failure"
          && u.serviceConfig.RestartSec == 30
          && u.serviceConfig.User == "root"
          && u.serviceConfig.NoNewPrivileges == hardening.NoNewPrivileges
          && u.unitConfig.StartLimitIntervalSec == "1h"
          && u.unitConfig.StartLimitBurst == 60
          && !(u.unitConfig ? ConditionPathExists)
          && u.wantedBy == [ "multi-user.target" ]
          && lib.elem "multi-user.target" u.after
          && lib.elem "multi-user.target" u.wants
        );
      message = "fixture: the NixOS check unit does not carry the documented retry/hardening shape";
    }
    {
      assertion =
        isDarwin || config.systemd.services.nixhold-check-fixture-program.serviceConfig.User == "nobody";
      message = "fixture: a check must run as the uid it names";
    }
    {
      # launchd has no start limit and no condition, so KeepAlive is
      # the whole retry, and the daemon runs as the declared uid.
      assertion =
        !isDarwin
        || (
          let
            c = config.launchd.daemons.nixhold-check-fixture.serviceConfig;
          in
          c.ProgramArguments == [ checks.fixture.program ]
          && c.RunAtLoad == true
          && c.KeepAlive.SuccessfulExit == false
          && c.ThrottleInterval == 30
          && c.UserName == "root"
          && config.launchd.daemons.nixhold-check-fixture-program.serviceConfig.UserName == "nobody"
        );
      message = "fixture: the darwin check daemon does not carry the documented KeepAlive shape";
    }
  ];
}
