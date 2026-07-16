# Minimal host stub used by the fixture flake.  It declares
# what the framework's baseline + chosen profile cannot fill
# in on its own (hardware-shaped bits the host normally owns).
# Kept here so the fixture is one self-contained directory.
{ lib, ... }:
{
  imports = [ ./modules/fixtureweb.nix ];

  # Exercise the caddy tailnet-TLS path (vhost + tailscale-cert units).
  nixhold.services.fixtureweb.enable = true;

  # Exercise the operator-key path end-to-end: owner defaults to
  # "user", homePath defaults to ".ssh/personal", the HM module emits
  # the symlink + `.pub` activation, and the committed
  # keys/hosts/fixture-server/identity.pub (derived from this
  # throwaway key) defaults `fleet.hosts.fixture-server.loginPubkey`.
  nixhold.secrets.personal = {
    sshIdentity = true;
    description = "Throwaway fixture SSH key (checked-in, not a real secret)";
  };

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
