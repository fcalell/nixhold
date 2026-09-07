# Syncthing — NixOS implementation.
#
# GUI on localhost, fronted by caddy at `<fqdn>/sync` on whichever
# network the host names in `expose.gui.network`. Devices and folders
# are added imperatively through the GUI (override* = false so they
# survive a rebuild). Sync ports (22000 tcp+udp, 21027 udp) are opened
# on the tailscale interface only.
#
# Posture — tailnet-only, and actually so. Upstream syncthing defaults
# are internet-facing (global discovery, relays, NAT-PMP/UPnP hole
# punching, crash reports, usage reporting); `settings.options` below
# turns all of that off, so this node talks to nothing but the peers
# it is told about. **Consequence: peers must be given this node's
# tailnet address statically** (Actions -> Advanced, or the device's
# Addresses field: `tcp://<host>.<magicDnsSuffix>:22000`) — with
# discovery off, nothing finds it on its own. Local (LAN) discovery is
# off too: the sync ports are open on the tailscale interface only, so
# a LAN peer could not connect on a discovered address anyway.
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
{ config, lib, ... }:
let
  cfg = config.nixhold.services.syncthing;
  user = config.nixhold.identity.username;
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
              extraConfig = "encode zstd gzip";
            };
          };

          # The GUI password, in plaintext: syncthing-init reads this
          # file and PATCHes the bcrypt hash of it into the running
          # config. Owned by the service account that reads it (mode
          # 0400), not by the operator. `required` is left at its
          # default (true) on purpose: without the ciphertext the host
          # fails to build, rather than deploying an unauthenticated
          # REST API that every local uid can drive. Provision it
          # before the first deploy —
          #   nixhold secret edit <host> syncthing
          nixhold.secrets.syncthing = {
            owner = "syncthing";
            category = "service";
            description = "Plaintext syncthing GUI password for the ${user} GUI login (syncthing-init bcrypts it into the running config)";
          };

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

          services.syncthing = {
            enable = true;
            dataDir = "/var/lib/syncthing";
            configDir = "/var/lib/syncthing/config";
            overrideDevices = false;
            overrideFolders = false;
            guiAddress = "127.0.0.1:8384";
            guiPasswordFile = config.age.secrets.syncthing.path;
            settings = {
              gui.user = lib.mkDefault user;
              # See the posture note in the header.
              # `settings.options` is PATCHed onto
              # /rest/config/options by syncthing-init on every
              # activation — independently of
              # override{Devices,Folders}, which only govern the
              # devices/folders sections — so these stay enforced
              # while paired devices remain imperative.
              options = {
                globalAnnounceEnabled = lib.mkDefault false;
                localAnnounceEnabled = lib.mkDefault false;
                relaysEnabled = lib.mkDefault false;
                natEnabled = lib.mkDefault false;
                crashReportingEnabled = lib.mkDefault false;
                urAccepted = lib.mkDefault (-1); # anonymous usage reporting: declined
              };
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
