# fixture-desktop — the fixture's desktopLinux host, and the only
# place that profile is built. It serves nothing and is on the tailnet
# alone: what it covers is the graphical-seat side of the framework —
# the wayland environment, the portal/audio/graphics stack and the
# identity wiring that only fires when NetworkManager is on. The
# compositor and its session entry are the host's, as on a real
# fleet; the stub brings the smallest ones.
{
  config,
  lib,
  pkgs,
  ...
}:
{
  programs.sway.enable = true;
  services.greetd = {
    enable = true;
    settings.default_session.command = "${pkgs.greetd.tuigreet}/bin/tuigreet --cmd sway";
  };

  # No machine ever ran `host install` for a fixture host, so there is
  # no report to point at: opt out of the facter guard.
  nixhold.hardware.facterReport = null;

  assertions = [
    {
      # The profile names no compositor, so it must set nothing that
      # names one: the session variable is the host's.
      assertion = !(config.environment.sessionVariables ? XDG_CURRENT_DESKTOP);
      message = "fixture-desktop: the desktopLinux profile names a compositor (XDG_CURRENT_DESKTOP)";
    }
    {
      # Wayland clients read these from PAM's environment, so they
      # have to be system-level and not compositor-level — a variable
      # set in a compositor config reaches its exec-once children and
      # nothing else.
      assertion = config.environment.sessionVariables.NIXOS_OZONE_WL == "1";
      message = "fixture-desktop: chromium/electron apps would run under XWayland — NIXOS_OZONE_WL is not exported at the session level";
    }
    {
      # Identity auto-wiring: the operator joins `networkmanager`
      # whenever NetworkManager is on, which on this profile it is by
      # default. A desktop whose operator cannot change networks
      # without sudo is the failure this pins.
      assertion =
        lib.elem "networkmanager"
          config.users.users.${config.nixhold.identity.username}.extraGroups;
      message = "fixture-desktop: the operator is not in the networkmanager group on a profile that enables NetworkManager";
    }
  ];
}
