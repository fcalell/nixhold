# Dummy hardware for fixture-gateway, the fixture host with no `disk`
# in the roster: the custom-layout path, where the operator's own
# module declares what the shipped shape would otherwise render. A
# `disko.devices` declaration is what a real host writes here; the
# fixture declares the resulting filesystems directly, plus the
# loader choice, so eval doesn't trip on a missing root filesystem or
# kernel modules.
{ lib, ... }:
{
  nixhold.hardware.facterReport = null;

  boot.loader.grub.enable = lib.mkDefault false;
  boot.loader.systemd-boot.enable = lib.mkDefault false;

  fileSystems."/" = lib.mkDefault {
    device = "/dev/disk/by-label/fixture-root";
    fsType = "ext4";
  };

  nixpkgs.hostPlatform = lib.mkForce "x86_64-linux";
  boot.initrd.availableKernelModules = [
    "ahci"
    "xhci_pci"
    "nvme"
    "usbhid"
  ];
}
