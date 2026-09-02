{ ... }:
{
  imports = [
    ./identity
    ./identity/darwin.nix
    ./layout
    ./types
    ./fleet
    ./fleet/derived.nix
    ./fleet/known-hosts.nix
    # The services index, not because a Mac runs any of them — it
    # runs none by default — but because `nixhold.services` is part
    # of every nixhold host's readable surface (`nixhold status`
    # walks it). A namespace that exists only where some profile
    # happened to import a service module is not a contract.
    ./services
    ./secrets
    ./secrets/darwin.nix
    ./cli
    ./home
    ./home/darwin.nix
  ];
}
