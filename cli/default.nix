# Packages the bash CLI as a single `writeShellApplication`. The
# resulting `nixhold` script has every runtime tool on PATH and
# can be invoked as `nix run path:.#nixhold -- <verb>` or pulled
# in via `programs.nixhold.enable` once that NixOS option lands.
{ pkgs }:
let
  defaults = import ../lib/defaults.nix;

  # `~/projects` is the option's operator-facing form. The wrapper
  # needs one bash expands: a quoted `~` stays literal, which
  # shellcheck rejects outright (SC2088).
  repositoriesDir =
    if pkgs.lib.hasPrefix "~" defaults.repositoriesDir then
      "$HOME" + pkgs.lib.removePrefix "~" defaults.repositoriesDir
    else
      defaults.repositoriesDir;
in
pkgs.writeShellApplication {
  name = "nixhold";

  runtimeInputs = with pkgs; [
    coreutils
    gnused
    gawk
    gnugrep
    jq
    gum
    openssh
    age
    rage
    # The operator's age seat may be a FIDO2 token: age spawns the
    # plugin for an `age1fido2-hmac1…` recipient at ENCRYPT time too
    # (the token itself is only needed to decrypt), and libfido2's
    # `fido2-token -L` is how the CLI tells a plugged-in token from a
    # drawer before it commits to that route.
    age-plugin-fido2-hmac
    libfido2
    # The framework-declared console password secret's generator.
    mkpasswd
    rsync
    nix
    git
    # `iso --flash` inspects the target device with lsblk before it
    # dd's over it; darwin has no lsblk, and that path is Linux-only.
    util-linux
    # Remote-install/deploy drivers: `host install` hard-requires
    # nixos-anywhere, and `deploy` needs nixos-rebuild even for
    # remote targets (darwin machines don't ship it).
    nixos-anywhere
    nixos-rebuild
    # `deploy` of an Android host is a converge over adb.
    android-tools
  ];

  # The framework's own lock rides along: lint's input-floor rule
  # measures the fleet's pins against it (rule 13).
  # The system this CLI runs on: an Android host's plan is built for
  # the seat, under `androidConfigurations.<system>`, so the verbs
  # must know which one they are.
  # And the framework's checkout directory, for the one verb that
  # runs before there is a fleet to evaluate (lib/defaults.nix).
  text = ''
    export NIXHOLD_LIB_ROOT="${./.}"
    export NIXHOLD_LOCK="${../flake.lock}"
    export NIXHOLD_SYSTEM="${pkgs.stdenv.hostPlatform.system}"
    export NIXHOLD_REPOSITORIES_DIR="${repositoriesDir}"
    exec bash "${./.}/nixhold.sh" "$@"
  '';
}
