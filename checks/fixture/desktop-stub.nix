# fixture-desktop — the fixture's desktopLinux host, and the only
# place that profile is built. It serves nothing and is on the tailnet
# alone: what it covers is the graphical-seat side of the framework —
# the wayland environment, the portal/audio/graphics stack and the
# identity wiring that only fires when NetworkManager is on. The
# compositor and its session entry are the host's, as on a real
# fleet; the stub brings the smallest ones. It is also the machine
# that runs fixture-guest ("Guests"): the assertions on the boundary
# — the container, the veth and NAT, the key bind, the device grant,
# the no-sleep rule — are here, the guest side in ./guest-stub.nix.
{
  config,
  lib,
  pkgs,
  ...
}:
{
  # The NixOS side of the checkout units: the desktop is the one
  # NixOS fixture host with a seat (`nixhold.home.checkouts`).
  imports = [ ./repositories.nix ];

  programs.sway.enable = true;
  services.greetd = {
    enable = true;
    settings.default_session.command = "${pkgs.greetd.tuigreet}/bin/tuigreet --cmd sway";
  };

  # No machine ever ran `host install` for a fixture host, so there is
  # no report to point at: opt out of the facter guard.
  nixhold.hardware.facterReport = null;

  assertions =
    let
      guest = config.containers.fixture-guest;
      derived = config.nixhold.fleet.derived.guests.fixture-guest;
    in
    [
      {
        # The container is the guest's own eval, reached by its
        # toplevel: one system, built once.
        assertion =
          lib.hasInfix "-nixos-system-fixture-guest-" guest.path
          && guest.autoStart
          && guest.privateNetwork
          && guest.enableTun
          && guest.hostAddress == derived.hostAddress
          && guest.localAddress == derived.localAddress
          && config.networking.nat.enable
          && lib.elem "ve-+" config.networking.nat.internalInterfaces;
        message = "fixture-desktop: the guest's container is not rendered from the roster";
      }
      {
        # The fleet key read-only, the render node bound and allowed,
        # the sound directory bound with the card's nodes opened at
        # runtime by the devices oneshot, and libudev's database for
        # both.
        assertion =
          guest.bindMounts."/etc/nixhold".isReadOnly
          && guest.bindMounts."/run/udev".isReadOnly
          && guest.bindMounts."/dev/dri/renderD128".hostPath == "/dev/dri/renderD128"
          && guest.bindMounts."/dev/snd".hostPath == "/dev/snd"
          &&
            guest.allowedDevices == [
              {
                node = "/dev/dri/renderD128";
                modifier = "rw";
              }
            ]
          && config.systemd.services.nixhold-guest-fixture-guest-devices.serviceConfig.NoNewPrivileges
          &&
            lib.elem "nixhold-guest-fixture-guest-devices.service"
              config.systemd.services."container@fixture-guest".wants;
        message = "fixture-desktop: the device grant is not rendered as the boundary describes";
      }
      {
        # The seat's wireplumber leaves the granted card alone.
        assertion =
          (lib.head config.services.pipewire.wireplumber.extraConfig."50-nixhold-guests"."monitor.alsa.rules")
          .matches == [ { "device.bus-id" = "usb-Fixture_Card_0001-00"; } ];
        message = "fixture-desktop: the granted card is not hidden from the machine's wireplumber";
      }
      {
        assertion =
          !config.systemd.sleep.settings.Sleep.AllowSuspend
          && config.services.logind.settings.Login.HandleLidSwitch == "ignore"
          && config.services.logind.settings.Login.HandlePowerKey == "ignore";
        message = "fixture-desktop: a machine with guests may still sleep";
      }
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
