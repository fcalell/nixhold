# The fixture declares its hosts inline in ./default.nix — mkFleet
# takes them as an argument, it never reads a file (principle 14).
# This one exists because `layout.hostsFile` defaults to it and the
# layout lint rule checks the default paths resolve; an empty attrset
# is the honest content, and a parseable one keeps `nix fmt` from
# choking on a zero-byte file.
{ }
