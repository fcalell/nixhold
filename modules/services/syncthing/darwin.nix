# Syncthing — Darwin implementation.
#
# A home-manager launchd agent under the operator's uid, folders under
# the operator's home, GUI on 127.0.0.1 only: a Mac is a seat, its
# syncthing holds the operator's own copies, and there is no service
# uid to hold them for them. Devices and folders come from the same
# `nixhold.fleet.sync` derivation the NixOS daemon renders
# (./default.nix), with the same tailnet-only posture — what differs
# is the folder path, which is why the path is per host in the
# declaration.
#
# No GUI password and no caddy vhost: the agent binds loopback on a
# machine with one human on it, and `expose` is a NixOS-only endpoint
# model (caddy is a NixOS module).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.nixhold.services.syncthing;
  user = config.nixhold.identity.username;

  # home-manager's launchd agent runs its own copy-keys step and then
  # execs `lib.getExe services.syncthing.package`; that step can only
  # copy files that already exist, and the identity is ONE ciphertext
  # where syncthing wants two files. So the split happens here, in the
  # program the agent runs, which is the only point between agenix and
  # the daemon's start that a Mac has: `home.activation` is the other
  # candidate and cannot be it — agenix decrypts asynchronously under
  # launchd on darwin, so activation routinely runs before the
  # plaintext is there.
  #
  # It is also what home-manager puts in the operator's profile as
  # `syncthing`, so a hand-run `syncthing device-id` re-splits the same
  # bundle before answering. Idempotent, and the identity it reports is
  # the one the agent is running.
  wrapper = pkgs.writeShellScriptBin "syncthing" ''
    set -euo pipefail
    umask 077
    bundle="${config.age.secrets.syncthing-identity.path}"
    if [ ! -r "$bundle" ]; then
      echo "syncthing: the identity at $bundle is not readable (agenix decrypts asynchronously on darwin) — not starting, since a syncthing with no identity mints a NEW device that no peer has been told about" >&2
      exit 1
    fi
    dir="$HOME/Library/Application Support/Syncthing"
    ${pkgs.coreutils}/bin/install -dm700 "$dir"
    # The bundle is key.pem then cert.pem; the certificate's BEGIN
    # line is where one ends and the other starts.
    ${pkgs.gawk}/bin/awk -v key="$dir/key.pem" -v cert="$dir/cert.pem" \
      '/^-----BEGIN CERTIFICATE-----/ { c = 1 } { print > (c ? cert : key) }' "$bundle"
    exec ${lib.getExe pkgs.syncthing} "$@"
  '';
in
{
  imports = [ ./default.nix ];

  config = lib.mkMerge [
    { nixhold.services.syncthing.implementation = "darwin"; }

    (lib.mkIf cfg.enable {
      # The identity's owner is left at the default — the operator,
      # whose agent is what reads it. The NixOS implementation is the
      # one that overrides it, with the daemon's uid.

      home-manager.users.${user}.services.syncthing = {
        enable = true;
        package = wrapper;
        guiAddress = "127.0.0.1:8384";
        # The GUI browses and shows folder state; a device or folder
        # added there is reverted at the next restart, because the
        # topology is the fleet's.
        overrideDevices = true;
        overrideFolders = true;
        settings = cfg.settings;
      };
    })
  ];
}
