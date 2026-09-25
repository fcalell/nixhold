# Hardware as data. NixOS-only.
#
# Two artifacts per host, both produced by `nixhold host install` from
# the target machine and neither authored by the operator:
#
#   - the install disk, `nixhold.fleet.hosts.<host>.disk` — a
#     /dev/disk/by-id path the disk picker writes into the roster. The
#     one shipped layout is rendered from it below: whole disk, GPT,
#     1G ESP mounted umask=0077 + ext4 root, inside LUKS2 when
#     `nixhold.hardware.encrypt` is set (the key is the fleet
#     passphrase, which `host install` proves and places at the
#     layout's `passwordFile` for the format). What the
#     shape implies (systemd-boot with EFI variables, zram swap — the
#     layout has no swap partition) is set alongside it at mkDefault. A host that
#     wants anything else declares `disko.devices` in its own module
#     and leaves `disk` null; install then formats what that names.
#   Neither applies to a guest (a host some machine's roster entry
#   names under `guests`): a container has no disk and no hardware to
#   report, so both default off there.
#   - the facter report, `nixhold.hardware.facterReport` — defaults to
#     `<layout.hostsDir>/<host>/facter.json`, a computed subpath like
#     every layout default; install writes it there. Until the file
#     exists the host still EVALUATES (so `nix eval`, lint and status
#     work) but a build is blocked by an assertion. The install
#     evaluates the disko script (which does not force `assertions`)
#     and writes the report before the closure is built, so the
#     assertion only trips on a plain rebuild of an un-installed host.
#
# The `hardware.facter` option set ships in nixpkgs; the disko module
# comes from the framework's own input, so no operator import.
{
  config,
  lib,
  inputs,
  ...
}:
let
  cfg = config.nixhold.hardware;
  fleet = config.nixhold.fleet;
  # A guest has no hardware of its own: the machine's is the
  # machine's to hand out (see "Guests"), so nothing below renders
  # for one — no layout, no loader, no swap, no report. Read from the
  # roster rather than `boot.isContainer`: the loader lines below sit
  # under `boot.*`, so a condition on a `boot.*` value is a cycle.
  isGuest = fleet.selfName != null && fleet.derived.guests ? ${fleet.selfName};
  disk = if fleet.derived.self == null || isGuest then null else fleet.derived.self.disk;
  declared = cfg.facterReport != null;
  present = declared && builtins.pathExists cfg.facterReport;
  rootFs = {
    type = "filesystem";
    format = "ext4";
    mountpoint = "/";
  };
in
{
  imports = [ inputs.nixhold.inputs.disko.nixosModules.disko ];

  options.nixhold.hardware.encrypt = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = ''
      Put the shipped layout's root partition inside LUKS2, unlocked
      at the console on every boot with the fleet passphrase (the
      string `operatorPassphrase` hashes). `nixhold host install`
      proves the string against that hash before anything is erased.
      Shapes the shipped layout only: a guest or a host with its own
      `disko.devices` cannot set it.
    '';
  };

  options.nixhold.hardware.facterReport = lib.mkOption {
    type = lib.types.nullOr lib.types.path;
    defaultText = lib.literalMD "`<layout.hostsDir>/<host>/facter.json`";
    description = ''
      Path to this NixOS host's nixos-facter hardware report, written
      by `nixhold host install`. When the file exists it is wired to
      `hardware.facter.reportPath`; until then the host still
      evaluates but a build is blocked by an assertion pointing at
      `nixhold host install`. Set this instead of assigning
      `hardware.facter.reportPath` directly, so the framework owns the
      pre-install guard; `null` opts out of both.
    '';
  };

  config = lib.mkMerge [
    {
      nixhold.hardware.facterReport = lib.mkDefault (
        if fleet.selfName == null || isGuest then
          null
        else
          config.nixhold.layout.hostsDir + "/${fleet.selfName}/facter.json"
      );
    }
    (lib.mkIf present {
      hardware.facter.reportPath = cfg.facterReport;
    })
    (lib.mkIf (declared && !present) {
      assertions = [
        {
          assertion = false;
          message = ''
            nixhold.hardware.facterReport (${toString cfg.facterReport}) does not
            exist yet — run `nixhold host install <host>` to generate it.
          '';
        }
      ];
    })
    (lib.mkIf (disk != null) {
      disko.devices.disk.main = {
        type = "disk";
        device = disk;
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              size = "1G";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                # Kernels, initrds and systemd-boot's random seed live
                # here; no other local account (a kiosk user, say) gets
                # to read them.
                mountOptions = [ "umask=0077" ];
              };
            };
            root = {
              size = "100%";
              content =
                if cfg.encrypt then
                  {
                    type = "luks";
                    name = "root";
                    # Read by disko at the format only, never by the
                    # booted system: `host install` writes the proven
                    # fleet passphrase here on the installer's /run and
                    # removes it when disko returns.
                    passwordFile = "/run/nixhold/disk-passphrase";
                    settings.allowDiscards = true;
                    content = rootFs;
                  }
                else
                  rootFs;
            };
          };
        };
      };
      boot.loader.systemd-boot.enable = lib.mkDefault true;
      boot.loader.efi.canTouchEfiVariables = lib.mkDefault true;
      zramSwap.enable = lib.mkDefault true;
    })
    (lib.mkIf (cfg.encrypt && disk == null) {
      assertions = [
        {
          assertion = false;
          message = ''
            nixhold.hardware.encrypt shapes the shipped layout, which this host
            does not use: a guest has no disk, and a host with its own
            `disko.devices` declares its `luks` content there.
          '';
        }
      ];
    })
  ];
}
