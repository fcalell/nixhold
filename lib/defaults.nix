# Framework defaults the CLI needs before a fleet checkout exists.
#
# Every other path in the CLI is derived: `nix eval` against the
# fleet answers where the secrets, keys and hosts live. A value
# belongs here only when the shell genuinely has nothing to evaluate
# — today that is the fresh-Mac bootstrap, which clones the checkout
# that every other answer comes from.
#
# Nix stays the single source: the modules read these, and
# `cli/default.nix` bakes them into the packaged `nixhold` as
# environment defaults, the way `$NIXHOLD_LOCK` is baked in.
{
  # `nixhold.home.repositoriesDir` (modules/home): where the
  # operator's checkouts live, the fleet's own included. A fleet that
  # overrides the option is honoured as soon as there is a checkout
  # to read it from — `nixhold host install` moves the clone there.
  repositoriesDir = "~/projects";
}
