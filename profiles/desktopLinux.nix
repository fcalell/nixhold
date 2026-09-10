# nixhold.profiles.desktopLinux — NixOS hyprland desktop defaults.
#
# Hostkind shape: operator's daily-driver Linux box. Hyprland plus the
# supporting wayland stack — session entry (greetd), graphics, audio,
# portals, the environment wayland clients read, and the file manager
# that goes with a graphical seat. Pulls in openssh + tailscale so the
# desktop is reachable from the rest of the fleet, but no
# caddy/firewall (a desktop doesn't terminate fleet HTTP).
#
# Everything here is `mkDefault`: a host that wants a display manager,
# another compositor's session, or its own portal set overrides the
# one option rather than opting out of the profile.
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

  nixpkgs.config.allowUnfree = lib.mkDefault true;

  # A machine the operator sits at roams: wifi, a tray applet, a VPN
  # entry the GUI can drive. The identity module adds the operator to
  # the `networkmanager` group whenever this is on.
  networking.networkmanager.enable = lib.mkDefault true;

  # A desktop is attended, so firmware updates are worth having (the
  # server profile turns fwupd off for the opposite reason).
  services.fwupd.enable = lib.mkDefault true;

  programs.hyprland = {
    enable = lib.mkDefault true;
    xwayland.enable = lib.mkDefault true;
  };

  # Single-TTY greeter, no display-manager bulk: greetd launches the
  # compositor directly. A host that wants a different session
  # overrides `settings.default_session`.
  services.greetd = {
    enable = lib.mkDefault true;
    settings.default_session = {
      command = lib.mkDefault "${pkgs.tuigreet}/bin/tuigreet --time --remember --cmd Hyprland";
      user = lib.mkDefault "greeter";
    };
  };

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

  xdg.portal = {
    enable = lib.mkDefault true;
    extraPortals = with pkgs; [ xdg-desktop-portal-hyprland ];
  };

  # FHS dynamic linker so downloaded binaries (editor servers, JetBrains
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
  # children only. Per-value mkDefault: a host overrides one variable
  # without dropping the rest.
  environment.sessionVariables = lib.mapAttrs (_: lib.mkDefault) {
    GDK_BACKEND = "wayland,x11";
    QT_QPA_PLATFORM = "wayland;xcb";
    SDL_VIDEODRIVER = "wayland";
    CLUTTER_BACKEND = "wayland";
    MOZ_ENABLE_WAYLAND = "1";

    NIXOS_OZONE_WL = "1";
    ELECTRON_OZONE_PLATFORM_HINT = "auto";

    _JAVA_AWT_WM_NONREPARENTING = "1";

    XDG_CURRENT_DESKTOP = "Hyprland";
    XDG_SESSION_TYPE = "wayland";
    XDG_SESSION_DESKTOP = "Hyprland";
  };

  # A graphical seat gets a file manager. Thunar does not auto-enable
  # tumbler/gvfs, so thumbnails and trash/sftp/smb mounts need both
  # named explicitly.
  programs.thunar = {
    enable = lib.mkDefault true;
    plugins = with pkgs; [
      thunar-volman
      thunar-archive-plugin
    ];
  };
  services.gvfs.enable = lib.mkDefault true;
  services.tumbler.enable = lib.mkDefault true;

  # Workstation fonts: a nerd font for the terminal and status bars,
  # font-awesome for the glyphs bar configs reach for, noto for
  # everything else including CJK and colour emoji. `fonts.packages`
  # is a list, so a fleet appends rather than overrides.
  fonts.packages = with pkgs; [
    nerd-fonts.jetbrains-mono
    font-awesome
    noto-fonts
    noto-fonts-cjk-sans
    noto-fonts-color-emoji
  ];

  environment.systemPackages = with pkgs; [
    ffmpegthumbnailer
    git
    htop
    libfido2
    ripgrep
    tmux
    vim
  ];

  system.stateVersion = lib.mkDefault "24.11";
}
