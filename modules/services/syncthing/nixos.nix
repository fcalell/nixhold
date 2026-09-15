# Syncthing — NixOS implementation.
#
# GUI on localhost, fronted by caddy at `<fqdn>/sync` on whichever
# network the host names in `expose.gui.network`. Devices and folders
# are the fleet's, derived in ./default.nix from `nixhold.fleet.sync`
# and rendered here with `override{Devices,Folders} = true`: the GUI
# browses and shows folder state, and anything added there is reverted
# at the next restart. Sync ports (22000 tcp+udp, 21027 udp) are
# opened on the tailscale interface only, which is also the one place
# a peer is dialled from — discovery, relays and NAT traversal are off
# (see ./default.nix).
#
# The daemon runs as its own `syncthing` service user (nixpkgs'
# default), never as the operator: nothing on a nixhold fleet runs as
# a human's uid. What it reaches outside its own tree is one group per
# data flow — `backups`, whose only member it is, for the nightly
# copies the backup-producing services write. Synced folders live
# under /srv/sync, owned by the daemon and shared with the operator's
# account through the `syncthing` group, so nothing here reaches into
# $HOME.
#
# The GUI is authenticated (`guiPasswordFile` + gui.user) because
# 127.0.0.1:8384 is not a boundary: every local uid can reach that
# port, and caddy's network identity auth guards the route, not the
# socket. `gui.user` is the operator's login name because it is a GUI
# credential and nothing more — it names no unix account.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.nixhold.services.syncthing;
  user = config.nixhold.identity.username;
  hardening = import ../../../lib/hardening.nix;

  # Where the identity bundle is split into the pair syncthing's own
  # ExecStartPre installs into configDir. A RuntimeDirectory of the
  # splitting unit: tmpfs, 0700, gone at reboot, and never a file the
  # daemon's state directory keeps a second copy of.
  identityDir = "/run/syncthing-identity";

  splitIdentity = pkgs.writeShellScript "syncthing-identity-split" ''
    set -euo pipefail
    umask 077
    ${pkgs.gawk}/bin/awk \
      -v key="$RUNTIME_DIRECTORY/key.pem" -v cert="$RUNTIME_DIRECTORY/cert.pem" \
      '/^-----BEGIN CERTIFICATE-----/ { c = 1 } { print > (c ? cert : key) }' \
      "${config.age.secrets.syncthing-identity.path}"
    for half in key cert; do
      if [ ! -s "$RUNTIME_DIRECTORY/$half.pem" ]; then
        echo "the syncthing identity holds no $half.pem — it must be the key followed by the certificate, as 'syncthing generate' writes them; re-mint it with 'nixhold secret edit ${toString config.nixhold.fleet.selfName} syncthing-identity'" >&2
        exit 1
      fi
    done
  '';
in
{
  imports = [ ./default.nix ];

  config = lib.mkMerge [
    { nixhold.services.syncthing.implementation = "nixos"; }

    (lib.mkIf cfg.enable (
      lib.mkMerge [
        {
          nixhold.services.syncthing = {
            network.ports.gui = 8384;
            expose.gui = {
              protocol = "https";
              backend = "gui";
              pathPrefix = "/sync";
              # A loopback-bound GUI refuses any Host that is not
              # loopback ("Host check error", 403) unless the check is
              # switched off, and caddy forwards the browser's Host as
              # is. Rewriting it keeps the check on: it is what stands
              # between the GUI and a DNS-rebinding page in a local
              # browser.
              extraConfig = ''
                encode zstd gzip
                request_header Host 127.0.0.1:${toString cfg.network.ports.gui}
              '';
            };
          };

          # The GUI password, in plaintext: syncthing-init reads this
          # file and PATCHes the bcrypt hash of it into the running
          # config. Owned by the service account that reads it (mode
          # 0400), not by the operator. `required` is left at its
          # default (true) on purpose: without the ciphertext the host
          # fails to build, rather than deploying an unauthenticated
          # REST API that every local uid can drive. Nobody types it:
          # the deploy that needs it runs the generator, and the
          # operator reads the minted password back when they log into
          # the GUI, with
          #   nixhold secret show <host> syncthing
          nixhold.secrets.syncthing = {
            owner = "syncthing";
            category = "service";
            generator = "openssl rand -base64 24";
            description = "Plaintext syncthing GUI password for the ${user} GUI login (syncthing-init bcrypts it into the running config)";
          };

          # The identity is declared in ./default.nix, platform-neutral
          # but for this: on NixOS the reader is the daemon's own uid.
          nixhold.secrets.syncthing-identity.owner = "syncthing";

          # nixpkgs creates the `syncthing` user and group (fixed
          # uid/gid, home = dataDir) as long as both are left at their
          # defaults, so only the extra membership is declared here:
          # read access to the nightly service backups, which is the
          # one thing this daemon needs outside its own trees.
          users.groups.backups = { };
          users.users.syncthing.extraGroups = [ "backups" ];

          # The operator's half of the sharing: their account reads
          # and writes what is synced, through the group of the daemon
          # that owns it. Not `backups` — that group is the backup
          # flow, and the operator has no business in it.
          users.users.${user}.extraGroups = [ "syncthing" ];

          # Where synced folders go. Off the operator's home (the
          # daemon is not that uid) and out of /var/lib/syncthing,
          # which is the daemon's own state — 0700, and a state wipe
          # would take the data with it. Setgid so everything created
          # below keeps the group the sharing depends on; no world
          # bits, so no other local uid looks in.
          systemd.tmpfiles.settings."10-syncthing"."/srv/sync".d = {
            user = "syncthing";
            group = "syncthing";
            mode = "2770";
          };

          # The identity arrives as one ciphertext and syncthing wants
          # two files, so one unit splits it before the daemon starts
          # and nixpkgs' own ExecStartPre copies the halves into
          # configDir. A unit rather than a step inside syncthing.service:
          # that unit's ExecStartPre is upstream's, and a second
          # definition of it would be a merge of a string with a list.
          systemd.services.syncthing-identity = {
            description = "Split the syncthing identity into the key and certificate the daemon starts from";
            requiredBy = [ "syncthing.service" ];
            before = [ "syncthing.service" ];
            serviceConfig = hardening // {
              Type = "oneshot";
              # A RuntimeDirectory is removed when its unit stops, and
              # syncthing.service reads the pair at every start.
              RemainAfterExit = true;
              RuntimeDirectory = baseNameOf identityDir;
              RuntimeDirectoryMode = "0700";
              # The reader of the ciphertext is the uid it is owned
              # by: the hardening set leaves root with no capability,
              # so nothing else could open a 0400 file of another uid.
              User = config.services.syncthing.user;
              Group = config.services.syncthing.group;
              ExecStart = splitIdentity;
            };
          };

          services.syncthing = {
            enable = true;
            dataDir = "/var/lib/syncthing";
            configDir = "/var/lib/syncthing/config";
            cert = "${identityDir}/cert.pem";
            key = "${identityDir}/key.pem";
            overrideDevices = true;
            overrideFolders = true;
            guiAddress = "127.0.0.1:8384";
            guiPasswordFile = config.age.secrets.syncthing.path;
            settings = cfg.settings // {
              gui.user = lib.mkDefault user;
            };
          };
        }

        # Sync protocol ports (22000 tcp+udp data, 21027 udp
        # discovery), opened only on the tailscale interface. Not an
        # `expose` endpoint: the sync protocol is not HTTP, and the
        # endpoint model is HTTP-family in v1 — so these are scoped
        # here, the same way the openssh module scopes port 22, rather
        # than through `networking.firewall.trustedInterfaces` (a
        # blanket trust that would also silently carry caddy's vhosts).
        (lib.mkIf config.services.tailscale.enable {
          networking.firewall.interfaces.${config.services.tailscale.interfaceName} = {
            allowedTCPPorts = [ 22000 ];
            allowedUDPPorts = [
              22000
              21027
            ];
          };
        })
      ]
    ))
  ];
}
