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

    # Operator SSH access fleet-wide: every line of the committed
    # keys/login.pub is authorized on the operator account (derived in
    # modules/fleet). Root login stays closed.
    openssh.authorizedKeys.keys = config.nixhold.fleet.derived.operatorAuthorizedKeys;

    # Console login. nixos-anywhere stages no password, so without
    # this a freshly installed box has a locked account at the tty —
    # and the tty is the one way in when ssh is not. The secret is
    # `required`, so this is unconditional: a host with no committed
    # ciphertext fails the secrets assertion with the fix spelled out,
    # rather than activating into an account nobody can authenticate
    # as at the keyboard.
    hashedPasswordFile = config.age.secrets.password.path;
  };

  # Declared by the framework so no fleet writes it: `host add` walks
  # it with the other missing secrets, and the CLI encrypts the hash
  # of the fleet passphrase, the string that wraps the operator
  # identity, from the one prompt that wrapped it (`operatorPassphrase`).
  # Fleet-scoped: one console password for the whole fleet, minted on
  # the first NixOS host and read by every later one — one ciphertext,
  # encrypted to the operator and the fleet key like everything else,
  # so a host added afterwards rekeys nothing. A darwin host never
  # declares it.
  nixhold.secrets.password = {
    scope = "fleet";
    owner = "root";
    # Required on NixOS: it is the way in when ssh is not. A host
    # with no console password is unreachable the moment the network
    # is — an unjoined tailnet, a broken interface, a reformat at the
    # machine's own keyboard — and the account is locked with no way
    # to log in and fix it. Requiring it costs nothing past the first
    # host: `password` is fleet-scoped and the first `host add` mints
    # the one ciphertext before any host is installed, so every later
    # host finds it already provisioned.
    required = true;
    category = "framework";
    operatorPassphrase = true;
    description = "console and sudo password for ${identity.username}, fleet-wide: the fleet passphrase, the string that wraps the operator identity (its yescrypt hash is what is stored)";
  };

  programs.zsh.enable = lib.mkDefault true;
}
