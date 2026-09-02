{ ... }:
{
  imports = [
    ./identity
    ./identity/nixos.nix
    ./layout
    ./types
    ./fleet
    ./fleet/derived.nix
    # Option namespace only (see ./services/default.nix). The NixOS
    # implementations stay profile-attached; what the baseline
    # guarantees is that `nixhold.services` is readable on every host,
    # whatever its profile imports.
    ./services
    ./secrets
    ./secrets/nixos.nix
    ./hardware
    ./cli
    ./home
    ./home/nixos.nix
  ];
}
