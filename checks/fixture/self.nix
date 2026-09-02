# The fixture's stand-in for `inputs.self`.
#
# A real forker's `self` is a store path of their whole checkout, and
# `mkFleet` roots every layout default on it — so anything the
# framework coerces out of `layout.*` carries a reference to that one
# path. Handing the fixture a bare `./.` would hide exactly that: it
# would be a subpath of the *framework's* source, indistinguishable
# from the framework's own references. `builtins.path` gives the
# fixture its own, separately named store path, so a check can tell
# "the image baked one ciphertext" from "the image swallowed the
# fleet".
builtins.path {
  path = ./.;
  name = "nixhold-fixture-fleet";
}
