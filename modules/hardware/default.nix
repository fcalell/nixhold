# Hardware as data. NixOS-only.
#
# Two artifacts per host, both produced by `nixhold host install` from
# the target machine and neither authored by the operator:
#
#   - the install disk, `nixhold.fleet.hosts.<host>.disk` — a
#     /dev/disk/by-id path the disk picker writes into the roster. The
#     one shipped layout is rendered from it below: whole disk, GPT,
#     512M ESP + ext4 root, no encryption. What the shape implies
#     (systemd-boot with EFI variables, zram swap — the layout has no
#     swap partition) is set alongside it at mkDefault. A host that
#     wants anything else declares `disko.devices` in its own module
#     and leaves `disk` null; install then formats what that names.
#   - the facter report, `nixhold.hardware.facterReport` — defaults to
#     `<layout.hostsDir>/<host>/facter.json`, a computed subpath like
#     every layout default; install writes it there. Until the file
#     exists the host still EVALUATES (so `nix eval`, lint and status
#     work) but a build is blocked by an assertion. nixos-anywhere
#     evaluates the disko script (which does not force `assertions`),
#     kexecs, writes the report, then builds the closure, so the
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
  disk = if fleet.derived.self == null then null else fleet.derived.self.disk;
  declared = cfg.facterReport != null;
  present = declared && builtins.pathExists cfg.facterReport;
in
{
  imports = [ inputs.nixhold.inputs.disko.nixosModules.disko ];

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
        if fleet.selfName == null then
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
              size = "512M";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
              };
            };
            root = {
              size = "100%";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/";
              };
            };
          };
        };
      };
      boot.loader.systemd-boot.enable = lib.mkDefault true;
      boot.loader.efi.canTouchEfiVariables = lib.mkDefault true;
      zramSwap.enable = lib.mkDefault true;
    })
  ];
}
