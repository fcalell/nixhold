# The Android baseline: what every Android host evaluates with, the
# way baseline-nixos.nix and baseline-darwin.nix are for theirs. The
# fleet contract every host shares (identity, layout, the fleet view
# and its derived addresses, the secrets declarations) and the
# android option tree. Nothing ssh-, home- or service-shaped: the
# device runs none of it.
{ ... }:
{
  imports = [
    ./identity
    ./layout
    # The shared option types the secrets declarations are typed with.
    ./types
    ./fleet
    ./fleet/derived.nix
    ./secrets
    ./android
  ];
}
