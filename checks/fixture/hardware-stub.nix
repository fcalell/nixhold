# Dummy hardware shared by the fixture's Linux hosts. Declares what
# the framework's baseline + chosen profile cannot fill in on its own
# (the hardware-shaped bits a real host owns), so eval doesn't trip on
# a missing root filesystem or kernel modules.
{ lib, ... }:
{
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
