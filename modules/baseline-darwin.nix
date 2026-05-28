{ ... }:
{
  imports = [
    ./identity
    ./identity/darwin.nix
    ./layout
    ./types
    ./fleet
    ./fleet/derived.nix
    ./secrets
    ./secrets/darwin.nix
    ./cli
    ./home
    ./home/darwin.nix
  ];
}
