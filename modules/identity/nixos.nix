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
    # Normal priority so a fleet's own extraGroups MERGE with these
    # rather than replace them (a mkDefault list is discarded whole by
    # any definition). networkmanager follows NetworkManager itself.
    extraGroups = [ "wheel" ] ++ lib.optional config.networking.networkmanager.enable "networkmanager";
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

    # Console login. nixos-anywhere stages no password, so without
    # this a freshly installed box has a locked account at the tty;
    # wired only once the secret is `active`, so a host evaluates
    # before it is provisioned (and a box only ever reached over ssh
    # never needs it).
    hashedPasswordFile = lib.mkIf config.nixhold.secrets.password.active config.age.secrets.password.path;
  };

  # Declared by the framework so no fleet writes it: `host add` walks
  # it with the other missing secrets, mkpasswd prompts for the
  # password on the terminal and emits the hash that is encrypted.
  nixhold.secrets.password = {
    owner = "root";
    required = false;
    generator = "mkpasswd -m yescrypt";
    description = "console login password for ${identity.username} (typed at the mkpasswd prompt; the hash is what is stored)";
  };

  programs.zsh.enable = lib.mkDefault true;
}
