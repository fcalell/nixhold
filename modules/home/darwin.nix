# Darwin half of the home-manager wiring: imports HM's darwin
# module plus the shared wiring in common.nix.
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  username = config.nixhold.identity.username;
in
{
  imports = [
    inputs.nixhold.inputs.home-manager.darwinModules.home-manager
    ./common.nix
  ];

  config = {
    home-manager.users.${username} = {
      # home-manager requires a stateVersion. nix-darwin's
      # `system.stateVersion` is an integer on a different scale, so
      # (unlike the NixOS half) we can't tie HM's release-string
      # stateVersion to it — default to the framework baseline.
      # mkDefault leaves a per-host HM module free to override.
      home.stateVersion = lib.mkDefault "24.11";

      # Apple's /usr/bin/ssh is built without FIDO2/security-key
      # support: it cannot use an `sk-ssh-ed25519@openssh.com` key at
      # all, so the token login posture (an `sk-` line in
      # `keys/login.pub`) would work from every Linux host in the
      # fleet and fail only on the Mac. HM's
      # `programs.ssh.package` puts the Nix-built openssh in the
      # operator's profile, ahead of /usr/bin on the PATH nix-darwin
      # composes, so `ssh` on this machine is the one that can talk
      # to the token. NixOS needs no equivalent — its ssh IS the Nix
      # build.
      programs.ssh.package = lib.mkDefault pkgs.openssh;
    };
  };
}
