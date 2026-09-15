{ lib, ... }:
{
  imports = [
    ./identity
    ./identity/nix.nix
    ./identity/nixos.nix
    ./layout
    ./types
    ./fleet
    ./fleet/derived.nix
    ./fleet/known-hosts.nix
    # Option namespace only (see ./services/default.nix). The NixOS
    # implementations stay profile-attached; what the baseline
    # guarantees is that `nixhold.services` is readable on every host,
    # whatever its profile imports.
    ./services
    # Backup publishing, the one infra module whose data is a
    # service's rather than a host kind's: a desktop that runs a
    # service with a `backup.dir` publishes the copies the same way a
    # server does. It activates from that data, so a host without one
    # renders nothing.
    ./infra/backups.nix
    ./secrets
    ./secrets/env.nix
    ./secrets/nixos.nix
    ./pins
    # Operator checkouts as fleet data: the env secret, the forge
    # ssh wiring, the direnv library and the clone step all follow
    # from one `nixhold.repositories` entry.
    ./repositories
    # What the fleet asserts about its own services, one system unit
    # each ("Provisioning": Checks are units too). Both baselines
    # carry it, so `nixhold.checks` exists on every host.
    ./checks
    ./checks/nixos.nix
    ./hardware
    # Both sides of "Guests": what a host sets when it is a container
    # of another host's machine, and what a machine renders for the
    # guests its roster entry names. Each gates itself on the roster.
    ./guests/guest.nix
    ./guests/machine.nix
    ./cli
    ./home
    ./home/nixos.nix
  ];

  # The framework owns the loader, so it owns how many generations the
  # boot menu carries. Two is enough to roll back the deploy that just
  # broke, and keeps /boot from filling on the small ESP the shipped
  # disko layout creates.
  boot.loader.systemd-boot.configurationLimit = lib.mkDefault 2;

  # /tmp on a tmpfs, fleet-wide. The CLI stages plaintext key material
  # under $XDG_RUNTIME_DIR when there is one and $TMPDIR otherwise, and
  # so does anything else that reaches for a temp file — none of which
  # should ever be written to a disk that outlives the boot. mkDefault:
  # a host that builds closures too big for RAM sets it back to false.
  boot.tmp.useTmpfs = lib.mkDefault true;
}
