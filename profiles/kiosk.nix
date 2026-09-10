# nixhold.profiles.kiosk — a screen nobody logs into, owned by the
# fleet end to end.
#
# Hostkind shape: an accountless Android device that shows one thing.
# Webview Kiosk is the launcher and the device owner (lock-task mode,
# the settings behind a credential, HOME pinned to it), Tailscale
# puts the device on the tailnet so the fleet reaches it by name, and
# network debugging is assumed on (it is how deploy gets in). What the
# screen shows or plays is the host module's: the page Webview Kiosk
# opens is set in the app, a media app is one more entry in
# `environment.systemPackages`.
#
# The APKs are GitHub release assets pinned by hash; a version moves
# by editing the two lines (ARCHITECTURE "Android hosts").
{ lib, pkgs, ... }:
let
  webviewKiosk = pkgs.fetchurl {
    url = "https://github.com/nktnet1/webview-kiosk/releases/download/v0.26.19/WebviewKiosk_v0.26.19.apk";
    hash = "sha256-3F9+Eobqmc724dmJUFwuX9DkH5tcJx9QRh3oNTbzyoc=";
  };
  tailscale = pkgs.fetchurl {
    url = "https://github.com/tailscale/tailscale-android/releases/download/1.102.3-t9329c3677-gf19372863/tailscale-android-universal-1.102.3.apk";
    hash = "sha256-zgH1ODeXaBRNfj8xcGqOtgOPyq5qo8QQqDvFYROsB2M=";
  };
in
{
  environment.systemPackages = [
    webviewKiosk
    tailscale
  ];

  # The app's own component names (its manifest): the HOME activity
  # and the device-admin receiver.
  android.launcher = lib.mkDefault "uk.nktnet.webviewkiosk/.MainActivity";
  android.deviceOwner = lib.mkDefault "uk.nktnet.webviewkiosk/.WebviewKioskAdminReceiver";
}
