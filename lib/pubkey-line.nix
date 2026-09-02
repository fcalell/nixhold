# First line of a committed pubkey file, trailing newline trimmed.
#
# Every consumer of a committed key file wants exactly this: age
# recipients, `authorized_keys` entries and `ssh_known_hosts` lines are
# all single-line, and the tools they feed (age, sshd, ssh) reject a
# stray newline. A file with a second line is an operator mistake worth
# failing on rather than silently truncating.
#
# `context` names the consuming option namespace so the throw points at
# the module that read the file, not just at the file.
context: path:
let
  m = builtins.match "([^\n]*)\n?" (builtins.readFile path);
in
if m == null then
  throw "${context}: ${toString path} must contain exactly one key line (found extra lines)"
else
  builtins.head m
