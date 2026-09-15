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
  inputs,
  guestToplevel,
  ...
}:
{
  # The NixOS side of the checkout units: the desktop is the one
  # NixOS fixture host with a seat (`nixhold.home.checkouts`).
  imports = [
    ./repositories.nix
    # The receiving end of the fixture's synced folder, on a host that
    # serves no HTTP: a desktopLinux box runs the same daemon a server
    # does (see ./default.nix's `sync`).
    inputs.nixhold.modules.services.nixos.syncthing
  ];

  nixhold.services.syncthing = {
    enable = true;
    # Required on the endpoint, and inert on this profile: the desktop
    # imports no caddy, so nothing serves the vhost and the GUI stays
    # on loopback where the operator already is.
    expose.gui.network = "tailnet";
  };

  programs.sway.enable = true;
  services.greetd = {
    enable = true;
    settings.default_session.command = "${lib.getExe pkgs.tuigreet} --cmd sway";
  };

  # No machine ever ran `host install` for a fixture host, so there is
  # no report to point at: opt out of the facter guard.
  nixhold.hardware.facterReport = null;

  assertions =
    let
      guest = config.containers.fixture-guest;
      unit = config.systemd.services."container@fixture-guest";
      derived = config.nixhold.fleet.derived.guests.fixture-guest;
    in
    [
      {
        # The container IS the guest's own eval: the same store path
        # `nixosConfigurations.fixture-guest` exports, one system built
        # once. An equality, not a name match: two evals of one module
        # list carry the same derivation name and different contents.
        assertion =
          guest.path == guestToplevel
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
        # The start path: the unit is up when nspawn is, and the veth
        # wait runs ahead of nixpkgs' post-start, which raises it.
        # `vm-guest` is what boots this.
        assertion =
          unit.serviceConfig.Type == "simple"
          && lib.hasSuffix "-wait-veth" (lib.head unit.serviceConfig.ExecStartPost);
        message = "fixture-desktop: the guest's container waits for the guest to signal ready before its veth is raised";
      }
      {
        # A boundary change restarts the guest, a closure change
        # reloads it: one trigger list each, holding nothing of the
        # other's. `reloadIfChanged` would collapse both into a reload.
        assertion =
          unit.reloadTriggers == [ guest.path ]
          && !unit.reloadIfChanged
          && lib.length unit.restartTriggers == 1
          && lib.hasInfix derived.hostAddress (lib.head unit.restartTriggers)
          && lib.hasInfix "/dev/dri/renderD128" (lib.head unit.restartTriggers)
          && !(lib.hasInfix "/nix/store" (lib.head unit.restartTriggers));
        message = "fixture-desktop: the guest's container restarts on its closure, or reloads on its boundary";
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
      {
        # The receiving end of `sync.backups`: this host's own path
        # and role, the history a receiver keeps, and the peers that
        # send it — everything off the one fleet declaration.
        assertion =
          let
            f = config.services.syncthing.settings.folders.backups;
          in
          f.path == "/srv/sync/backups"
          && f.type == "receiveonly"
          && f.versioning.type == "staggered"
          && f.versioning.params.maxAge == "31536000"
          &&
            f.devices == [
              "fixture-mac"
              "fixture-server"
            ];
        message = "fixture-desktop: the synced folder is not this host's entry in nixhold.fleet.sync";
      }
      {
        # Retention belongs to the receiver, so the sender carries
        # none: the same folder on fixture-server is versionless, and
        # a producer that rotated its own copies would be a second
        # policy for this one to disagree with.
        assertion = config.nixhold.fleet.sync.backups.fixture-server.versioning == null;
        message = "fixture-desktop: the sending end of the folder declares versioning of its own";
      }
      {
        # The identity: one ciphertext, split into the pair the daemon
        # starts from by a unit ordered ahead of it, and read by the
        # uid that owns it.
        assertion =
          let
            split = config.systemd.services.syncthing-identity;
          in
          config.services.syncthing.key == "/run/syncthing-identity/key.pem"
          && config.services.syncthing.cert == "/run/syncthing-identity/cert.pem"
          && split.serviceConfig.RuntimeDirectory == "syncthing-identity"
          && split.serviceConfig.User == "syncthing"
          && split.serviceConfig.NoNewPrivileges
          && lib.elem "syncthing.service" split.before
          && config.nixhold.secrets.syncthing-identity.resolvedOwner == "syncthing"
          && config.nixhold.secrets.syncthing-identity.resolvedMode == "0400";
        message = "fixture-desktop: the syncthing identity is not split into the daemon's pair by a unit ahead of it";
      }
    ];
}
