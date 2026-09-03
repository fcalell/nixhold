# Packages the bash CLI as a single `writeShellApplication`. The
# resulting `nixhold` script has every runtime tool on PATH and
# can be invoked as `nix run path:.#nixhold -- <verb>` or pulled
# in via `programs.nixhold.enable` once that NixOS option lands.
{ pkgs }:
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
  ];

  text = ''
    export NIXHOLD_LIB_ROOT="${./.}"
    exec bash "${./.}/nixhold.sh" "$@"
  '';
}
