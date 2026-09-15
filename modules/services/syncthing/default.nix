# Syncthing — option namespace, and the topology both implementations
# render.
#
# Split from the implementations (./nixos.nix, ./darwin.nix) for the
# reason spelled out in ../openssh/default.nix: the namespace is
# baseline-wide, the implementation is per-platform and
# profile-attached. What is NOT split is the config the two share —
# devices, folders and the tailnet-only posture, all derived from
# `nixhold.fleet.sync` — because both platforms read the same fleet
# data and only the folder paths differ, which is why the path is per
# host in the declaration (see "Syncthing: identity and topology are
# fleet data").
#
# Identity is the `syncthing-identity` secret: the key and certificate
# syncthing minted, one PEM bundle, with the device ID derived from it
# at mint time and committed to `keys/syncthing/<host>.id`. Every
# peer's device list is rendered from those committed files, which is
# also why the identity is a secret and not a per-install mint like the
# ssh host key: a wipe that lost it would re-pair every peer.
{ config, lib, ... }:
let
  cfg = config.nixhold.services.syncthing;
  types' = config.nixhold.types;

  fleet = config.nixhold.fleet;
  self = fleet.selfName;

  # This host's folders: the entries of `sync` that name it. A host's
  # eval sees the whole topology and takes its own slice of it.
  myFolders =
    if self == null then { } else lib.filterAttrs (_: members: members ? ${self}) fleet.sync;

  # A folder's peers: the other hosts holding it. A name that is no
  # roster host is dropped here and reported by the assertion below,
  # so the operator reads that message rather than an attribute error.
  peersOf = members: lib.filter (h: h != self && fleet.hosts ? ${h}) (lib.attrNames members);
  peers = lib.unique (lib.concatMap peersOf (lib.attrValues myFolders));

  # The committed device ID of a peer. Same named principle-14
  # exception as `keys/hosts/<host>.pub`: the path is computed off
  # `keysDir`, and `pathExists` only says whether that one computed
  # path is populated.
  pubkeyLine = import ../../../lib/pubkey-line.nix "nixhold.services.syncthing";
  idPath = peer: config.nixhold.layout.keysDir + "/syncthing/${peer}.id";
  deviceId =
    peer:
    let
      p = idPath peer;
    in
    if builtins.pathExists p then pubkeyLine p else null;

  # Where a peer is dialled. Discovery and relays are off, so the
  # address is the only way to it: the first tailscale network the two
  # hosts share. No `addressOf` guess — this spells out the network
  # class, and a peer sharing none of them is an assertion.
  selfNets = if fleet.derived.self == null then [ ] else fleet.derived.self.networks;
  peerAddress =
    peer:
    let
      shared = lib.filter (
        n: fleet.network.${n}.type == "tailscale" && lib.elem n fleet.hosts.${peer}.networks
      ) selfNets;
      addrs = lib.filter (a: a != null) (map (n: fleet.derived.address.${peer}.${n}) shared);
    in
    if addrs == [ ] then null else lib.head addrs;

  missingId = lib.filter (p: deviceId p == null) peers;
  unreachable = lib.filter (p: peerAddress p == null) peers;
  # A peer the config can name: both halves are there. Leaving a
  # half-known peer out keeps the assertions below the error the
  # operator sees, instead of a type failure inside nixpkgs' own
  # syncthing module.
  renderable = lib.filter (p: !(lib.elem p missingId) && !(lib.elem p unreachable)) peers;

  notInRoster = lib.concatLists (
    lib.mapAttrsToList (
      folder: members:
      map (h: "${folder}.${h}") (lib.filter (h: !(fleet.hosts ? ${h})) (lib.attrNames members))
    ) fleet.sync
  );
in
{
  options.nixhold.services.syncthing = {
    enable = lib.mkEnableOption "Syncthing, GUI behind caddy and sync over the tailnet";

    implementation = lib.mkOption {
      internal = true;
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Set by the platform implementation module when one is
        attached. Enabling a service whose implementation this host
        never imported would otherwise be a silent no-op.
      '';
    };

    network = lib.mkOption {
      type = types'.network;
      default = { };
    };

    expose = lib.mkOption {
      type = types'.expose;
      default = { };
      description = ''
        The implementation declares the `gui` endpoint whole —
        backend port and path prefix — except for its `network`,
        which is fleet data: the host names the network it wants the
        GUI reachable on (`expose.gui.network = "tailnet"`). NixOS
        only: caddy is a NixOS module, and a Mac's GUI is the
        operator's own on localhost. The sync protocol itself is not
        an endpoint (it is not HTTP); its ports are opened on the
        tailscale interface directly.
      '';
    };

    settings = lib.mkOption {
      internal = true;
      readOnly = true;
      type = lib.types.attrs;
      description = ''
        `services.syncthing.settings` for this host, derived from
        `nixhold.fleet.sync` and the committed device IDs: the
        folders naming this host, the peers holding them, and the
        tailnet-only posture. Both platform implementations render
        this one value — what the daemon and the launchd agent
        disagree about is where a folder lives, which is a fact of
        the declaration and not of the platform.
      '';
    };
  };

  config = lib.mkMerge [
    {
      nixhold.services.syncthing.settings = {
        devices = lib.genAttrs renderable (peer: {
          id = deviceId peer;
          addresses = [ "tcp://${peerAddress peer}:22000" ];
          # A peer offering a folder this host was not told about is
          # offering a path nothing declared.
          autoAcceptFolders = false;
        });

        folders = lib.mapAttrs (
          _: members:
          let
            mine = members.${self};
          in
          {
            inherit (mine) path type;
            devices = lib.filter (p: lib.elem p renderable) (peersOf members);
          }
          // lib.optionalAttrs (mine.versioning != null) { inherit (mine) versioning; }
        ) myFolders;

        # Upstream syncthing defaults are internet-facing (global
        # discovery, relays, NAT-PMP/UPnP hole punching, crash
        # reports, usage reporting); all of it is off, so a node talks
        # to nothing but the peers it is told about, over the tailnet
        # its sync port is open on. Local (LAN) discovery goes too:
        # the port is open on no other interface, so a LAN peer could
        # not connect on a discovered address anyway.
        #
        # Per-value mkDefault: a fleet overrides one of these without
        # restating the block.
        options = lib.mapAttrs (_: lib.mkDefault) {
          globalAnnounceEnabled = false;
          localAnnounceEnabled = false;
          relaysEnabled = false;
          natEnabled = false;
          crashReportingEnabled = false;
          urAccepted = -1; # anonymous usage reporting: declined
        };
      };

      assertions = [
        {
          assertion = !cfg.enable || cfg.implementation != null;
          message = "nixhold.services.syncthing is enabled but no implementation is attached on this host — import `nixhold.modules.services.<nixos|darwin>.syncthing`.";
        }
        {
          # Checked on every host, because the topology is one fleet
          # value: a name in it that is nobody is a typo wherever it is
          # read from.
          assertion = notInRoster == [ ];
          message = "nixhold.fleet.sync names hosts that are not in this fleet's roster: ${lib.concatStringsSep ", " notInRoster}. Every `sync.<folder>.<host>` key must be a key in mkFleet's `hosts`.";
        }
        {
          assertion = myFolders == { } || cfg.enable;
          message = "${toString self} carries the synced folder(s) ${lib.concatStringsSep ", " (lib.attrNames myFolders)} in nixhold.fleet.sync, but nixhold.services.syncthing.enable is false on it — enable the service (and import its implementation), or take the host out of those folders.";
        }
      ];
    }

    (lib.mkIf cfg.enable {
      # The key and the certificate syncthing minted, as one PEM
      # bundle: the identity every peer's device list pins. `required`
      # by default — a host without it comes up as a brand new device
      # no peer knows. The implementation owns the runtime owner: the
      # daemon's uid on NixOS, the operator's (the default) on a Mac,
      # whose launchd agent is what reads it.
      #
      # The device ID is not in the ciphertext: it is derived from the
      # same plaintext by `public.command` and committed, so a peer's
      # eval reads a file instead of a secret it cannot open.
      nixhold.secrets.syncthing-identity = {
        category = "service";
        description = "syncthing's TLS key and certificate (one PEM bundle) — the device identity ${toString self} is known to its peers by";
        generator = ''
          (
            umask 077
            d="$(mktemp -d)" || exit 1
            trap 'rm -rf "$d"' EXIT INT TERM
            # `syncthing generate` logs to STDOUT, which here is the
            # secret itself: everything but the bundle goes to stderr.
            syncthing generate --home "$d" >&2 || exit 1
            cat "$d/key.pem" "$d/cert.pem" || exit 1
            echo "syncthing device ID of ${toString self}: $(syncthing device-id --home "$d")" >&2
          )
        '';
        public = {
          file = "syncthing/${toString self}.id";
          command = ''
            (
              umask 077
              d="$(mktemp -d)" || exit 1
              trap 'rm -rf "$d"' EXIT INT TERM
              # The bundle is key.pem then cert.pem; the certificate's
              # BEGIN line is where one ends and the other starts.
              awk -v key="$d/key.pem" -v cert="$d/cert.pem" \
                '/^-----BEGIN CERTIFICATE-----/ { c = 1 } { print > (c ? cert : key) }' || exit 1
              syncthing device-id --home "$d" || exit 1
            )
          '';
        };
      };

      assertions = [
        {
          assertion = missingId == [ ];
          message = "syncthing on ${toString self}: no committed device ID for peer(s) ${lib.concatStringsSep ", " missingId} — ${
            lib.concatStringsSep ", " (map (p: toString (idPath p)) missingId)
          } is missing. `nixhold secret edit <peer> syncthing-identity` mints that peer's identity and writes the file.";
        }
        {
          assertion = unreachable == [ ];
          message = "syncthing on ${toString self}: peer(s) ${lib.concatStringsSep ", " unreachable} share no tailscale network with this host, so there is no address to dial them at (discovery and relays are off). Put both hosts on the same tailscale-typed network in mkFleet's `hosts`.";
        }
      ];
    })
  ];
}
