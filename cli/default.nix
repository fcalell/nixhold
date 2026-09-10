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
  ];

  # The framework's own lock rides along: lint's input-floor rule
  # measures the fleet's pins against it (rule 13).
  text = ''
    export NIXHOLD_LIB_ROOT="${./.}"
    export NIXHOLD_LOCK="${../flake.lock}"
    exec bash "${./.}/nixhold.sh" "$@"
  '';
}
