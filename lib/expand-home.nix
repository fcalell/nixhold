# `~` in an operator-facing path string, resolved against one home.
#
# Operator-facing path options (`nixhold.home.repositoriesDir`, a
# repository's `path`) are written the way a shell prompt shows them,
# with a leading `~`. Every consumer needs the absolute form: a clone
# target, a direnv prefix test and the fleet directory baked into the
# CLI wrapper are all compared against `$PWD`-shaped strings, which
# carry no `~`.
#
# `~` alone and `~/…` expand; anything else — an absolute path, or a
# `~user` form the framework does not support — is returned unchanged.
home: path:
if path == "~" then
  home
else if builtins.substring 0 2 path == "~/" then
  home + builtins.substring 1 (builtins.stringLength path) path
else
  path
