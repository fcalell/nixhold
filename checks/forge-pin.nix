# The failing half of "The first clone is not TOFU"
# (modules/repositories): a repository on a forge no `knownHosts` entry
# covers is an eval error, not a unit that retries `Host key
# verification failed` until its start limit.
#
# The passing half is the fixture itself — it declares repositories on
# three forges and evaluates only because all three are pinned. A
# failing assertion cannot live in a host that has to build, so this
# reads the assertion list of a fixture host extended with a repository
# on an unpinned forge, then with that forge pinned: the one failure,
# then none.
{ pkgs, fixture }:
let
  inherit (pkgs) lib;

  forge = "stray.fixture.invalid";
  publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixtureStrayForgeKeyAAAAAAAAAAAAAAAAAAA";

  # fixture-gateway declares no repository of its own, so what its
  # assertions say about this one is the module's answer alone.
  failures =
    extra:
    map (a: a.message) (
      lib.filter (a: !a.assertion) (
        (fixture.nixosConfigurations.fixture-gateway.extendModules {
          modules = [
            { nixhold.repositories.stray = "git@${forge}:fixture/stray.git"; }
            extra
          ];
        }).config.assertions
      )
    );

  unpinned = failures { };
  pinned = failures { programs.ssh.knownHosts.${forge}.publicKey = publicKey; };

  problems =
    lib.optional (!(lib.length unpinned == 1 && lib.hasInfix forge (lib.head unpinned)))
      "a repository on the unpinned forge ${forge} must fail exactly the pin assertion, got ${builtins.toJSON unpinned}"
    ++ lib.optional (
      pinned != [ ]
    ) "pinning ${forge} in programs.ssh.knownHosts left ${builtins.toJSON pinned}";
in
if problems == [ ] then
  pkgs.runCommand "nixhold-forge-pin" { } "touch $out"
else
  throw "nixhold-forge-pin: ${lib.concatStringsSep "; " problems}"
