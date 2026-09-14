# nixhold.profiles.desktopLinux — the NixOS graphical seat.
#
# Hostkind shape: operator's daily-driver Linux box. The seat end to
# end — graphics, audio, portals, polkit, the toolkit wayland
# variables PAM exports, NetworkManager, nix-ld, the FIDO2 token —
# and no application: the compositor, the session entry that launches
# it, the portal that goes with it, the file manager, fonts and tools
# are the fleet's, in the host module that carries the compositor.
# Pulls in openssh + tailscale so the desktop is reachable from the
# rest of the fleet, but no caddy/firewall (a desktop doesn't
# terminate fleet HTTP).
#
# Everything here is `mkDefault`: a host overrides the one option
# rather than opting out of the profile.
{
  inputs,
  lib,
  pkgs,
  ...
}:
{
  imports = [
    inputs.nixhold.modules.services.nixos.openssh
    inputs.nixhold.modules.services.nixos.tailscale
  ];

  nixhold.services.openssh.enable = lib.mkDefault true;
  nixhold.services.tailscale.enable = lib.mkDefault true;

  # Store hygiene: weekly gc + optimise on every shipped profile.
  nix.gc = {
    automatic = lib.mkDefault true;
    dates = lib.mkDefault "weekly";
    options = lib.mkDefault "--delete-older-than 14d";
  };
  nix.optimise = {
    automatic = lib.mkDefault true;
    dates = lib.mkDefault [ "weekly" ];
  };

  # A machine the operator sits at roams: wifi, a tray applet, a VPN
  # entry the GUI can drive. The identity module adds the operator to
  # the `networkmanager` group whenever this is on.
  networking.networkmanager.enable = lib.mkDefault true;

  # A desktop is attended, so firmware updates are worth having (the
  # server profile turns fwupd off for the opposite reason).
  services.fwupd.enable = lib.mkDefault true;

  # The operator's FIDO2 token is used from the desktop, not only
  # from the installer: `age-plugin-fido2-hmac` for secrets and
  # `ssh -o SecurityKeyProvider` / an sk key for fleet login both
  # reach the token through libfido2, which needs its udev rules for
  # the hidraw node to be readable without root. `fido2-token` is on
  # PATH so enrolling and listing credentials is a local operation.
  services.udev.packages = [ pkgs.libfido2 ];

  # Wayland desktop essentials.
  security.polkit.enable = lib.mkDefault true;
  security.rtkit.enable = lib.mkDefault true;

  # System-level so dbus can expose dconf to user sessions.
  programs.dconf.enable = lib.mkDefault true;

  # rtkit above is what keeps usb/bluetooth audio from crackling:
  # without realtime priority pipewire misses its deadlines.
  services.pipewire = {
    enable = lib.mkDefault true;
    alsa.enable = lib.mkDefault true;
    alsa.support32Bit = lib.mkDefault true;
    pulse.enable = lib.mkDefault true;
    jack.enable = lib.mkDefault true;
    wireplumber.enable = lib.mkDefault true;
  };

  hardware.graphics = {
    enable = lib.mkDefault true;
    enable32Bit = lib.mkDefault true;
  };

  # The portal service; the compositor's own portal is the fleet's
  # (`xdg.portal.extraPortals` is a list, so it appends).
  xdg.portal.enable = lib.mkDefault true;

  # FHS dynamic linker so downloaded binaries (editor servers, IDE
  # tooling, vendored toolchain libs) can load their .so deps — a
  # workstation runs software it did not build.
  programs.nix-ld = {
    enable = lib.mkDefault true;
    libraries = with pkgs; [
      stdenv.cc.cc.lib
      zlib
      openssl
      curl
      libxml2
      libxslt
      icu
      glib
      nss
      nspr
    ];
  };

  # PAM exports these at login, so shells, `systemd --user` and the
  # compositor's own children all inherit them. Belongs to the profile
  # rather than to a compositor config, which reaches exec-once
  # children only. The compositor-named ones (`XDG_CURRENT_DESKTOP`,
  # `XDG_SESSION_DESKTOP`) are the fleet's, beside the compositor.
  # Per-value mkDefault: a host overrides one variable without
  # dropping the rest.
  environment.sessionVariables = lib.mapAttrs (_: lib.mkDefault) {
    GDK_BACKEND = "wayland,x11";
    QT_QPA_PLATFORM = "wayland;xcb";
    SDL_VIDEODRIVER = "wayland";
    CLUTTER_BACKEND = "wayland";
    MOZ_ENABLE_WAYLAND = "1";

    NIXOS_OZONE_WL = "1";
    ELECTRON_OZONE_PLATFORM_HINT = "auto";

    _JAVA_AWT_WM_NONREPARENTING = "1";

    XDG_SESSION_TYPE = "wayland";
  };

  # `git`: the CLI clones the operator's repositories. `libfido2`:
  # the token route above.
  environment.systemPackages = with pkgs; [
    git
    libfido2
  ];

  system.stateVersion = lib.mkDefault "24.11";
}
