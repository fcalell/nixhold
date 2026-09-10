# fixture-mobile — the `mobile` profile's host: a person's device. The
# profile installs nothing and seizes nothing; the host module carries
# the vendor's removals and the person's settings. The plan builds
# with an empty package list, which is the shape a phone normally has.
{ config, ... }:
{
  android.removedPackages = [ "com.example.preload" ];
  android.settings.global.animator_duration_scale = "0.5";

  assertions = [
    {
      assertion = config.android.launcher == null && config.android.deviceOwner == null;
      message = "fixture-mobile: the mobile profile sets no launcher and no device owner";
    }
    {
      assertion = config.environment.systemPackages == [ ];
      message = "fixture-mobile: the mobile profile installs nothing";
    }
  ];
}
