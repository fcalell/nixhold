{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (config.nixhold) identity;
in
{
  users.users.${identity.username} = {
    isNormalUser = lib.mkDefault true;
    home = lib.mkDefault "/home/${identity.username}";
    description = lib.mkDefault identity.fullName;
    # Pinned, not autoincrement-assigned — keeps uid/gid stable
    # across reinstalls and reachable from non-NixOS mounts.
    uid = lib.mkDefault 1000;
    extraGroups = lib.mkDefault [ "wheel" ];
    # Normal priority, not mkDefault: nixpkgs already defines the
    # per-user shell at mkDefault (via `useDefaultShell` →
    # `users.defaultUserShell`, itself mkDefault bashInteractive in
    # bash.nix). Two mkDefaults tie and error, so the framework's
    # opinionated zsh must outrank that default. A host that wants a
    # different shell overrides with `lib.mkForce`.
    shell = pkgs.zsh;

    # Operator SSH access fleet-wide: every host's loginPubkey is
    # authorized on the operator account (derived in modules/fleet).
    openssh.authorizedKeys.keys = config.nixhold.fleet.derived.operatorAuthorizedKeys;
  };

  programs.zsh.enable = lib.mkDefault true;
}
