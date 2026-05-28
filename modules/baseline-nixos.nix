{ ... }:
{
  imports = [
    ./identity
    ./identity/nixos.nix
    ./layout
    ./types
    ./fleet
    ./fleet/derived.nix
    ./secrets
    ./secrets/nixos.nix
    ./hardware
    ./cli
    ./home
    ./home/nixos.nix
  ];
}
