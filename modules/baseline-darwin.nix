{ ... }:
{
  imports = [
    ./identity
    ./identity/nix.nix
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
    ./secrets/env.nix
    ./secrets/darwin.nix
    ./pins
    # Operator checkouts as fleet data: the env secret, the forge
    # ssh wiring, the direnv library and the clone step all follow
    # from one `nixhold.repositories` entry.
    ./repositories
    # What the fleet asserts about its own services, one launchd
    # daemon each ("Provisioning": Checks are units too).
    ./checks
    ./checks/darwin.nix
    ./cli
    ./home
    ./home/darwin.nix
  ];
}
