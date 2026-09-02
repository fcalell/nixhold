# Services index — the `nixhold.services` option namespace.
#
# Both platform baselines import this, which is what makes
# `config.nixhold.services` answerable on every nixhold host (and
# `nixhold status` uniform across NixOS and darwin). It carries
# option declarations only: nothing here activates, and nothing here
# implements. The platform implementations live beside each service
# as `<service>/nixos.nix` and are what `nixhold.modules.services.*`
# points at — profiles import the ones they need (principle 14: an
# explicit list, no fs discovery). Each implementation re-imports its
# own `<service>/default.nix` by the same path this index uses, so
# the module system folds the two entry points into one declaration.
{ ... }:
{
  imports = [
    ./openssh/default.nix
    ./tailscale/default.nix
  ];
}
