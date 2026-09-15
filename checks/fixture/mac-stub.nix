# fixture-mac — the darwin half of the syncthing topology.
#
# A Mac is a seat: its syncthing is a home-manager launchd agent under
# the operator's uid, with the folders in their home and the GUI on
# loopback. What this asserts is that the agent renders the SAME fleet
# data the NixOS daemon does — the peers of the folders naming this
# host, their committed device IDs, their tailnet addresses — off the
# one `nixhold.fleet.sync` declaration in ./default.nix.
{
  config,
  lib,
  inputs,
  ...
}:
let
  hm = config.home-manager.users.${config.nixhold.identity.username}.services.syncthing;
  keys = ./keys/syncthing;
in
{
  # The forker idiom: a host imports the implementation of what it
  # enables.
  imports = [ inputs.nixhold.modules.services.darwin.syncthing ];

  nixhold.services.syncthing.enable = true;

  assertions = [
    {
      # Exactly its peers — the other two hosts of the `backups`
      # folder — each with the device ID committed for it and the
      # address it is dialled at over the tailnet the three share.
      assertion =
        lib.attrNames hm.settings.devices == [
          "fixture-desktop"
          "fixture-server"
        ]
        && hm.settings.devices.fixture-server.id == lib.fileContents "${keys}/fixture-server.id"
        && hm.settings.devices.fixture-server.addresses == [ "tcp://fixture-server.fixture.ts.net:22000" ]
        && hm.settings.devices.fixture-desktop.id == lib.fileContents "${keys}/fixture-desktop.id"
        && hm.settings.devices.fixture-desktop.addresses == [ "tcp://fixture-desktop.fixture.ts.net:22000" ]
        && !hm.settings.devices.fixture-server.autoAcceptFolders
        && !hm.settings.devices.fixture-desktop.autoAcceptFolders;
      message = "fixture-mac: the launchd agent's devices are not the committed identities of this folder's peers";
    }
    {
      # The folder is this host's entry of the declaration: its own
      # path, its own role, and no versioning where none was declared.
      assertion =
        hm.settings.folders.backups.path == "/Users/fixture/Sync/backups"
        && hm.settings.folders.backups.type == "receiveonly"
        && hm.settings.folders.backups.versioning == null
        &&
          hm.settings.folders.backups.devices == [
            "fixture-desktop"
            "fixture-server"
          ];
      message = "fixture-mac: the synced folder is not this host's entry in nixhold.fleet.sync";
    }
    {
      # The topology is the fleet's: a device or folder added in the
      # GUI is reverted at the next restart.
      assertion = hm.overrideDevices && hm.overrideFolders;
      message = "fixture-mac: the launchd agent lets GUI-added devices or folders survive a restart";
    }
    {
      # The same tailnet-only posture the NixOS daemon takes: nothing
      # is announced, nothing is relayed, and the identity is the
      # operator's own secret rather than the daemon uid's.
      assertion =
        !hm.settings.options.globalAnnounceEnabled
        && !hm.settings.options.localAnnounceEnabled
        && !hm.settings.options.relaysEnabled
        && hm.guiAddress == "127.0.0.1:8384"
        && config.nixhold.secrets.syncthing-identity.resolvedOwner == config.nixhold.identity.username;
      message = "fixture-mac: the launchd agent's posture or its identity's owner is not the seat's";
    }
    {
      # The public half of that secret: the file a peer's eval reads,
      # named after this host, and the command that derives it.
      assertion = config.nixhold.secrets.syncthing-identity.public.file == "syncthing/fixture-mac.id";
      message = "fixture-mac: the syncthing identity does not commit its device ID under keys/syncthing/<host>.id";
    }
  ];
}
