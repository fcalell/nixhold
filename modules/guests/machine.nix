# The machine side of "Guests": what a NixOS host renders for every
# guest its roster entry names, read from `nixhold.fleet.derived.guests`
# (modules/fleet/derived.nix). The guest's system itself is the one
# thing not set here — mkFleet points `containers.<guest>.path` at the
# guest's own eval — so this module is the boundary and nothing else.
#
# Three things cross it, all from the roster entry:
#
#   - Network. A private veth pair, the guest's end and the machine's
#     end derived once for both sides; the machine masquerades what
#     leaves it, on whatever uplink it has at the time (no
#     `externalInterface`: a seat roams). tailscaled in the guest needs
#     the tun device and the network capability, which `enableTun`
#     grants. nixpkgs' own container module already leaves `ve-*`
#     alone under NetworkManager and dhcpcd.
#   - The fleet key. /etc/nixhold, read-only: the guest decrypts every
#     ciphertext with the key the machine holds, and `deploy` ensures
#     it once, on the machine.
#   - Devices. A render node is bound as it is: the kernel time-slices
#     a GPU between every process on the machine, so a guest sharing
#     it costs the seat nothing it does not already share with its
#     own applications. A sound card is handed over whole: the
#     machine's /dev/snd is visible in the guest — a device directory
#     is bound or not — and the device cgroup is what lets the guest
#     open that card's nodes and no other. Which nodes those are is
#     runtime knowledge (a by-id link resolves to a card index the
#     kernel assigns), so a oneshot before the container start resolves
#     the grant and sets the unit's DeviceAllow; a udev rule re-runs
#     it when a card appears, and `set-property` applies live. The
#     machine's wireplumber, when the seat has one, disables the
#     granted card by its bus id — the same string the by-id link is
#     named from — so the guest's pipewire is its only owner. /run/udev
#     is bound read-only whenever a device is granted: a container has
#     no udev of its own, and libudev reads the database there to find
#     the cards and render nodes it may open.
#
# The container unit's own semantics are set here too, because they
# follow from the shape above and not from the fleet that uses it.
# nixpkgs' unit is Type=notify and raises the machine's end of the veth
# in its post-start, which runs only once the guest signals ready, and
# a guest that runs networkd's wait-online and tailscaled cannot reach
# ready until that end is up. On a machine whose network manager
# leaves `ve-*` alone (every NetworkManager seat) that is a deadlock
# the unit cuts at its start timeout, on repeat. So the unit counts as
# started the moment nspawn is, and its post-start waits for the veth
# to exist before nixpkgs' script raises it.
# What restarts it is then the boundary (the bind mounts, the device
# grant, the tun device, the veth addresses, the nspawn flags), and
# what reloads it is the guest's closure alone: nixpkgs' ExecReload
# runs the new system's switch-to-configuration inside the running
# guest, restarting only the guest units that changed, where a restart
# halts and boots the guest. Any deploy moves the closure, so the two
# must not share one trigger list.
#
# A machine with guests never sleeps: suspend and hibernate are off
# and the lid and power key do nothing, mkDefault so a host can take
# the decision back. The seat's idle policy for the screen is its own.
#
# Auto-activates from data; no enable knob.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  fleet = config.nixhold.fleet;
  mine =
    if fleet.selfName == null then
      { }
    else
      lib.filterAttrs (_: g: g.machine == fleet.selfName) fleet.derived.guests;

  isRender = lib.hasPrefix "/dev/dri/";
  isCard = lib.hasPrefix "/dev/snd/by-id/";
  renderNodes = g: lib.filter isRender g.devices;
  cards = g: lib.filter isCard g.devices;
  withCards = lib.filterAttrs (_: g: cards g != [ ]) mine;
  granted = lib.unique (lib.concatMap (g: g.devices) (lib.attrValues mine));

  hardening = import ../../lib/hardening.nix;

  # nixhold-guest-<guest>-devices: resolve each granted card to its
  # nodes and open them to the container's cgroup. A card that is not
  # plugged in is skipped with a warning — the guest starts without
  # it and takes it when it appears — rather than keeping the whole
  # guest down for one device.
  deviceUnit =
    guest: g:
    let
      script = pkgs.writeShellScript "nixhold-guest-${guest}-devices" ''
        set -eu
        props=()
        for link in ${lib.escapeShellArgs (cards g)}; do
          if ! ctl="$(readlink -f "$link")" || [ ! -e "$ctl" ]; then
            echo "nixhold: ${guest}: $link is not present — the guest starts without it" >&2
            continue
          fi
          n="''${ctl#/dev/snd/controlC}"
          for node in /dev/snd/controlC"$n" /dev/snd/pcmC"$n"D* /dev/snd/hwC"$n"D* /dev/snd/midiC"$n"D*; do
            [ -e "$node" ] || continue
            props+=("DeviceAllow=$node rw")
          done
        done
        if [ "''${#props[@]}" -gt 0 ]; then
          systemctl set-property --runtime container@${guest}.service "''${props[@]}"
        fi
      '';
    in
    {
      description = "Resolve the sound cards granted to guest ${guest}";
      before = [ "container@${guest}.service" ];
      serviceConfig = hardening // {
        Type = "oneshot";
        ExecStart = script;
        # The card nodes are what it resolves, and systemd's bus is
        # where the answer goes.
        PrivateDevices = false;
      };
    };

  # container@<guest>: nixpkgs' unit, with the start path and the
  # change semantics this framework needs (see the header).
  containerUnit =
    guest: g:
    let
      c = config.containers.${guest};
    in
    {
      # The boundary. Everything here defines the nspawn instance
      # itself, and half of it (the nspawn flags the bind mounts
      # render, the two addresses) reaches the unit only through
      # /etc/nixos-containers/<guest>.conf, which is not the unit file,
      # so it needs a trigger to be noticed at all. mkForce because
      # nixpkgs' own list holds the guest's closure, which belongs
      # below.
      restartTriggers = lib.mkForce [
        (builtins.toJSON {
          inherit (c)
            bindMounts
            allowedDevices
            enableTun
            hostAddress
            localAddress
            extraFlags
            ;
        })
      ];
      # The closure. A changed X-Reload-Triggers and an otherwise
      # unchanged unit file is switch-to-configuration's one reload
      # case; `reloadIfChanged` would instead make EVERY unit change a
      # reload, including the boundary above.
      reloadTriggers = [ c.path ];

      serviceConfig = {
        Type = lib.mkForce "simple";
        ExecStartPost = lib.mkBefore [
          (pkgs.writeShellScript "nixhold-guest-${guest}-wait-veth" ''
            for _ in $(seq 1 100); do
              ${pkgs.iproute2}/bin/ip link show ve-${guest} >/dev/null 2>&1 && exit 0
              sleep 0.2
            done
            echo "nixhold: ve-${guest} did not appear" >&2
            exit 1
          '')
        ];
      };
    }
    // lib.optionalAttrs (cards g != [ ]) {
      wants = [ "nixhold-guest-${guest}-devices.service" ];
      after = [ "nixhold-guest-${guest}-devices.service" ];
    };
in
{
  config = lib.mkIf (mine != { }) {
    assertions = [
      {
        # The CLI names /var/lib/nixos-containers/<guest> directly:
        # `deploy` reads the guest's first ssh host key out of it and
        # `host remove` prints it as the state the operator keeps or
        # wipes. nixpkgs drops the "nixos-" prefix below this
        # stateVersion, and the CLI would then be reading a path that
        # does not exist.
        assertion = lib.versionAtLeast config.system.stateVersion "22.05";
        message = "nixhold guests: ${fleet.selfName} runs guests at system.stateVersion ${config.system.stateVersion}, but nixpkgs keeps container state under /var/lib/containers below 22.05 and the CLI reads /var/lib/nixos-containers/<guest>. Raise the machine's system.stateVersion to 22.05 or later.";
      }
    ]
    ++ lib.mapAttrsToList (address: guests: {
      assertion = lib.length guests == 1;
      message = "nixhold guests: ${lib.concatStringsSep " and " guests} are both guests of ${fleet.selfName} and both derive the veth pair ${address}. The /24 comes from a hash of the guest's name, so the resolution is to rename one of them: 'nixhold host remove <guest>' and 'nixhold host add' under a new name.";
    }) (lib.groupBy (guest: mine.${guest}.hostAddress) (lib.attrNames mine));

    containers = lib.mapAttrs (guest: g: {
      autoStart = true;
      privateNetwork = true;
      inherit (g) hostAddress localAddress;
      enableTun = true;
      bindMounts = {
        "/etc/nixhold" = {
          hostPath = "/etc/nixhold";
          isReadOnly = true;
        };
      }
      // lib.optionalAttrs (g.devices != [ ]) {
        "/run/udev" = {
          hostPath = "/run/udev";
          isReadOnly = true;
        };
      }
      // lib.optionalAttrs (cards g != [ ]) {
        "/dev/snd" = {
          hostPath = "/dev/snd";
          isReadOnly = false;
        };
      }
      // lib.listToAttrs (
        map (
          node:
          lib.nameValuePair node {
            hostPath = node;
            isReadOnly = false;
          }
        ) (renderNodes g)
      );
      allowedDevices = map (node: {
        inherit node;
        modifier = "rw";
      }) (renderNodes g);
    }) mine;

    networking.nat = {
      enable = true;
      internalInterfaces = [ "ve-+" ];
    };

    systemd.services =
      lib.mapAttrs' (
        guest: g: lib.nameValuePair "nixhold-guest-${guest}-devices" (deviceUnit guest g)
      ) withCards
      // lib.mapAttrs' (guest: g: lib.nameValuePair "container@${guest}" (containerUnit guest g)) mine;

    # A card that appears after boot: resolve again, live.
    services.udev.extraRules = lib.concatMapStrings (guest: ''
      ACTION=="add", SUBSYSTEM=="sound", KERNEL=="controlC*", TAG+="systemd", ENV{SYSTEMD_WANTS}+="nixhold-guest-${guest}-devices.service"
    '') (lib.attrNames withCards);

    # The seat's wireplumber, when there is one, leaves the granted
    # cards to their guests. `device.bus-id` is udev's ID_ID, which is
    # also what names the /dev/snd/by-id link.
    services.pipewire.wireplumber.extraConfig =
      lib.mkIf (config.services.pipewire.wireplumber.enable && lib.any isCard granted)
        {
          "50-nixhold-guests"."monitor.alsa.rules" = map (card: {
            matches = [ { "device.bus-id" = baseNameOf card; } ];
            actions.update-props."device.disabled" = true;
          }) (lib.filter isCard granted);
        };

    systemd.sleep.settings.Sleep = {
      AllowSuspend = lib.mkDefault false;
      AllowHibernation = lib.mkDefault false;
      AllowHybridSleep = lib.mkDefault false;
      AllowSuspendThenHibernate = lib.mkDefault false;
    };
    services.logind.settings.Login = {
      HandleLidSwitch = lib.mkDefault "ignore";
      HandleLidSwitchExternalPower = lib.mkDefault "ignore";
      HandleLidSwitchDocked = lib.mkDefault "ignore";
      HandlePowerKey = lib.mkDefault "ignore";
    };
  };
}
