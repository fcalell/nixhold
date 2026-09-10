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
    ./secrets
    ./secrets/env.nix
    ./secrets/nixos.nix
    # Operator checkouts as fleet data: the env secret, the forge
    # ssh wiring, the direnv library and the clone step all follow
    # from one `nixhold.repositories` entry.
    ./repositories
    ./hardware
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
