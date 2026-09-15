# The script one checkout provisioning unit runs (ARCHITECTURE
# "Provisioning"). A function of the repository alone, so
# checks/repositories-script.nix runs the same script against a local
# origin that a fleet host runs against its forge.
#
# Exit 0 is done; any other exit is "not yet" and the unit retries (the
# network, the key, the forge: each is a retry, never a silent skip).
# An `.envrc` in the checkout is the done marker, tested here as well
# as in the unit's condition, because launchd has no start condition.
#
# `dir` is the checkout, `keyHomePath` the outbound key relative to
# `$HOME` (null for a URL that needs none), `direnv` whether the
# operator runs direnv.
{
  pkgs,
  name,
  url,
  dir,
  keyHomePath ? null,
  direnv ? false,
}:
let
  inherit (pkgs.lib) escapeShellArg makeBinPath optionalString;
in
pkgs.writeShellScript "nixhold-repo-${name}" ''
  set -euo pipefail
  # A unit's PATH is the manager's, not a login shell's, and
  # git spawns ssh by name.
  export PATH=${
    makeBinPath [
      pkgs.git
      pkgs.openssh
      pkgs.coreutils
      pkgs.gnugrep
    ]
  }:$PATH
  repo=${escapeShellArg dir}
  [ ! -e "$repo/.envrc" ] || exit 0
  if [ ! -e "$repo" ]; then
    ${optionalString (keyHomePath != null) ''
      if [ ! -r "$HOME/${keyHomePath}" ]; then
        echo "nixhold: ~/${keyHomePath} is not readable yet — ${name} waits for it" >&2
        exit 1
      fi
    ''}
    git clone ${escapeShellArg url} "$repo"
  fi
  # An .envrc is what makes direnv load at all; nixhold only ever
  # creates a missing one, never touches the repository's own (the
  # clone above may well have brought one), and never pulls. Tested
  # again here: the test before the clone cannot see what the clone
  # writes. Written last: it is the marker, so a failure before it is
  # a retry.
  managed=0
  if [ ! -e "$repo/.envrc" ]; then
    # The exclude entry keeps the managed file out of a repository
    # whose other contributors never asked for it; a repository that
    # tracks its own .envrc is never ignored.
    if [ -d "$repo/.git" ] && ! git -C "$repo" ls-files --error-unmatch .envrc >/dev/null 2>&1; then
      mkdir -p "$repo/.git/info"
      grep -qxF '.envrc' "$repo/.git/info/exclude" 2>/dev/null \
        || echo '.envrc' >> "$repo/.git/info/exclude"
    fi
    echo '# managed by nixhold: repository env is loaded by ~/.config/direnv/lib/nixhold.sh' > "$repo/.envrc"
    managed=1
  fi
  ${optionalString direnv ''
    ${pkgs.direnv}/bin/direnv allow "$repo" || {
      # Only what this script wrote is removed, so the next run is a
      # retry; the repository's own .envrc stays and is the marker.
      [ "$managed" -eq 0 ] || rm -f "$repo/.envrc"
      exit 1
    }
  ''}
''
