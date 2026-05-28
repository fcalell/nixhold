# Minimal host stub used by the fixture flake.  It declares
# what the framework's baseline + chosen profile cannot fill
# in on its own (hardware-shaped bits the host normally owns).
# Kept here so the fixture is one self-contained directory.
{ lib, ... }:
{
  imports = [ ./modules/fixtureweb.nix ];

  # Exercise the caddy tailnet-TLS path (vhost + tailscale-cert units).
  nixhold.services.fixtureweb.enable = true;

  boot.loader.grub.enable = lib.mkDefault false;
  boot.loader.systemd-boot.enable = lib.mkDefault false;

  fileSystems."/" = lib.mkDefault {
    device = "/dev/disk/by-label/fixture-root";
    fsType = "ext4";
  };

  # Dummy hardware so eval doesn't trip on missing kernel options.
  nixpkgs.hostPlatform = lib.mkForce "x86_64-linux";
  boot.initrd.availableKernelModules = [
    "ahci"
    "xhci_pci"
    "nvme"
    "usbhid"
  ];
}
