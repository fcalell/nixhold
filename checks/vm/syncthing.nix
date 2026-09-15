# The syncthing identity, run rather than evaluated: one ciphertext
# holds the key and the certificate, and the daemon wants two files in
# its configDir. The fixture builds that wiring; only a boot says
# whether the device that comes up is the device whose ID the fleet
# committed — which is the whole reason the identity is a secret and
# not a per-install mint (a wipe that changed it would re-pair every
# peer).
#
# The module list is the handful the units come from, not a fleet:
# mkFleet's baseline would bring provisioning and a tailnet join,
# neither of which this reads. agenix is not here either — age is not
# available in a VM check — so the option it declares is stubbed with
# the one field the module reads, pointed at a bundle minted at build
# time and placed where a decrypted secret would be.
{ pkgs }:
let
  # What `nixhold secret edit <host> syncthing-identity` mints: the
  # key and the certificate concatenated, plus the device ID its
  # `public` command would have committed to keys/syncthing/<host>.id.
  identity = pkgs.runCommand "vm-syncthing-identity" { nativeBuildInputs = [ pkgs.syncthing ]; } ''
    mkdir -p $out home
    syncthing generate --home home >/dev/null
    cat home/key.pem home/cert.pem >$out/bundle.pem
    syncthing device-id --home home >$out/device-id
  '';
in
pkgs.testers.runNixOSTest {
  name = "nixhold-syncthing";

  nodes.machine =
    { lib, ... }:
    {
      imports = [
        ../../modules/types
        ../../modules/fleet
        ../../modules/fleet/derived.nix
        ../../modules/identity
        ../../modules/secrets/default.nix
        ../../modules/services/syncthing/nixos.nix
      ];

      options.age.secrets = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.submodule { options.path = lib.mkOption { type = lib.types.str; }; }
        );
        default = { };
      };

      config = {
        nixhold.identity = {
          username = "vmop";
          fullName = "VM Operator";
          email = "vmop@example.invalid";
        };
        users.users.vmop.isNormalUser = true;

        # One folder, one host: enough for the settings the module
        # derives to reach the running daemon. Peers are the fixture's
        # ground (this VM has no tailnet to dial one over).
        nixhold.fleet = {
          selfName = "machine";
          hosts.machine = {
            arch = "x86_64-linux";
            profile = { };
          };
          sync.local.machine.path = "/srv/sync/local";
        };

        nixhold.services.syncthing = {
          enable = true;
          expose.gui.network = "localhost";
        };

        # No ciphertexts to point at, and nothing here decrypts: the
        # two files the module reads are placed by /etc instead.
        nixhold.secrets = {
          syncthing.required = lib.mkForce false;
          syncthing-identity.required = lib.mkForce false;
        };
        age.secrets = {
          syncthing.path = "/etc/syncthing-gui-password";
          syncthing-identity.path = "/etc/syncthing-identity.pem";
        };
        environment.etc = {
          "syncthing-identity.pem" = {
            source = "${identity}/bundle.pem";
            user = "syncthing";
            mode = "0400";
          };
          "syncthing-gui-password" = {
            text = "vm-throwaway";
            user = "syncthing";
            mode = "0400";
          };
        };
      };
    };

  testScript = ''
    machine.wait_for_unit("syncthing.service")

    # The device that came up is the one the mint named: the split
    # unit wrote the pair, syncthing's own ExecStartPre installed it
    # into configDir, and the daemon adopted it instead of generating
    # an identity of its own.
    expected = machine.succeed("cat ${identity}/device-id").strip()
    got = machine.succeed(
        "syncthing device-id --home /var/lib/syncthing/config"
    ).strip()
    assert got == expected, f"{got} != {expected}"

    # The pair lives in a RuntimeDirectory of the splitting unit, 0700
    # under the daemon's uid — the plaintext identity is never a file
    # of the daemon's state directory.
    machine.succeed("stat -c '%U %a' /run/syncthing-identity | grep -qx 'syncthing 700'")

    # And the folder the fleet declared is the folder the daemon runs,
    # written into its config by syncthing-init.
    machine.wait_for_unit("syncthing-init.service")
    machine.succeed("grep -q '/srv/sync/local' /var/lib/syncthing/config/config.xml")
  '';
}
