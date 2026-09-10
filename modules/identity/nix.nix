# The nix daemon's operator wiring, on the platforms that run one
# (NixOS and nix-darwin both expose `nix.settings`). mkDefault so a
# host or profile overrides without `mkForce`. `root` stays in
# trusted-users: writing the setting replaces nix.conf's built-in
# `trusted-users = root`. Flakes are on everywhere because every CLI
# verb needs them on every host.
{ config, lib, ... }:
{
  nix.settings = {
    trusted-users = lib.mkDefault [
      "root"
      config.nixhold.identity.username
    ];
    experimental-features = lib.mkDefault [
      "nix-command"
      "flakes"
    ];
  };
}
