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
    rsync
    nix
  ];

  text = ''
    export NIXHOLD_LIB_ROOT="${./.}"
    exec bash "${./.}/nixhold.sh" "$@"
  '';
}
