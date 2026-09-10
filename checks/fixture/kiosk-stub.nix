# fixture-kiosk — the `kiosk` profile's host: the fleet-owned screen.
# The profile carries the launcher, the device owner and the APKs;
# this stub adds what a screen's host module would (a setting) and
# asserts the two things an Android host is for: it reads the fleet
# like every other host (its own tailnet address is derived), and the
# kiosk shape is what the profile set.
{ config, ... }:
{
  android.settings.global.stay_on_while_plugged_in = "7";

  assertions = [
    {
      assertion =
        config.nixhold.fleet.derived.address.fixture-kiosk.tailnet == "fixture-kiosk.fixture.ts.net";
      message = "fixture-kiosk: an Android host's tailnet address is derived like any host's";
    }
    {
      assertion = config.android.launcher != null && config.android.deviceOwner != null;
      message = "fixture-kiosk: the kiosk profile sets the launcher and the device owner";
    }
    {
      assertion = builtins.length config.environment.systemPackages == 2;
      message = "fixture-kiosk: the kiosk profile carries exactly the kiosk app and Tailscale";
    }
    {
      assertion = config.nixhold.secrets.adb.scope == "fleet" && config.nixhold.secrets.adb.required;
      message = "fixture-kiosk: the adb key is a required fleet secret on every Android host";
    }
  ];
}
