# Every key line in a committed pubkey file: newline-split, trimmed,
# blanks and `#` comments dropped.
#
# The sibling of ./pubkey-line.nix, for the two files that are
# legitimately LISTS. `keys/operator.pub`: the operator reaches their
# own secrets by more than one route — a FIDO2 hardware token
# (`age1fido2-hmac1…`), a passphrase-wrapped identity (`age1…`), or
# both at once — and each route is a recipient of its own, so a secret
# encrypted today is readable by whichever route the operator has to
# hand tomorrow. `keys/login.pub`: one ssh login pubkey per key the
# operator carries, so a lost token is not a lost fleet.
#
# Single-line files (`keys/fleet.pub`, `keys/hosts/<h>.pub`) keep
# using ./pubkey-line.nix: a second line there is an operator mistake
# worth failing on, not a second route.
path:
let
  segments = builtins.filter builtins.isString (builtins.split "\n" (builtins.readFile path));
  trim =
    s:
    let
      m = builtins.match "[[:space:]]*(.*[^[:space:]])[[:space:]]*" s;
    in
    if m == null then "" else builtins.head m;
  trimmed = map trim segments;
in
builtins.filter (l: l != "" && !(builtins.substring 0 1 l == "#")) trimmed
