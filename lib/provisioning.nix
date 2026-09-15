# One provisioning unit, rendered for both managers (ARCHITECTURE
# "Provisioning"). Two consumers: `nixhold.repositories`, one
# user-scope unit per checkout, and `nixhold.checks`, one system-scope
# unit per assertion the fleet makes about its services. What they
# share is the retry, and sharing it here is what keeps them from
# drifting on it.
#
# The spec:
#
#   description  the unit's description. The unit's NAME is the
#                attribute the caller keys the rendering under, in the
#                manager's own namespace.
#   script       the program the unit runs. Exit 0 is done, any other
#                exit is "not yet" and the unit is re-run.
#   done         a path whose existence means the work is already
#                there, or null for a unit that runs on every start.
#                It renders as the systemd start condition, which
#                SKIPS the unit rather than failing it; launchd has no
#                start condition, so a script with a marker tests it
#                itself (modules/repositories/checkout.nix).
#   after        the units this one is ordered after and pulls in.
#   scope        "user" for home-manager's managers,
#                `systemd.user.services` and `launchd.agents`, or
#                "system" for the platform's own,
#                `systemd.services` and nix-darwin's `launchd.daemons`.
#                Each manager takes its own attrset shape, which is why
#                one retry renders as four of them.
{ lib }:
{
  description,
  script,
  done ? null,
  after ? [ ],
  scope ? "user",
}:
let
  user = scope == "user";

  # The retry IS the dependency: a user manager has no
  # network-online.target and a check's evidence lands whenever the
  # service it reads gets there, so a unit that cannot do its work
  # yet fails and is started again every 30 s. `Type=exec` rather than
  # `oneshot`: home-manager's sd-switch waits for the start job of a
  # newly wanted unit, and a oneshot's job lasts the whole run.
  service = {
    Type = "exec";
    ExecStart = "${script}";
    Restart = "on-failure";
    RestartSec = 30;
  };

  # Bounded on systemd: an hour's worth of attempts, then `failed`
  # for as long as the manager lives: nothing re-triggers it but the
  # next login or the next deploy, which resets and starts the
  # `nixhold-*` units for exactly that reason.
  limit = {
    StartLimitIntervalSec = "1h";
    StartLimitBurst = 60;
  };
  condition = lib.optionalAttrs (done != null) { ConditionPathExists = "!${done}"; };

  # launchd has neither a start limit nor a condition:
  # `KeepAlive.SuccessfulExit = false` re-runs the program every
  # ThrottleInterval seconds until it exits 0, unbounded.
  # `KeepAlive.NetworkState` is not used: Apple documents it as no
  # longer implemented.
  plist = {
    ProgramArguments = [ "${script}" ];
    RunAtLoad = true;
    KeepAlive.SuccessfulExit = false;
    ThrottleInterval = 30;
  };
in
{
  systemd =
    if user then
      {
        Unit = {
          Description = description;
        }
        // limit
        // condition
        // lib.optionalAttrs (after != [ ]) {
          After = after;
          Wants = after;
        };
        Service = service;
        Install.WantedBy = [ "default.target" ];
      }
    else
      {
        inherit description;
        serviceConfig = service;
        unitConfig = limit // condition;
        wantedBy = [ "multi-user.target" ];
      }
      // lib.optionalAttrs (after != [ ]) {
        inherit after;
        wants = after;
      };

  launchd =
    if user then
      {
        enable = true;
        config = plist;
      }
    else
      { serviceConfig = plist; };
}
