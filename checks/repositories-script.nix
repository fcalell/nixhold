# The checkout script (modules/repositories/checkout.nix) run against
# two real git origins: one that commits its own `.envrc` (helm, stack
# and sailward all do), one that does not.
#
# No forge and no ssh: the origins are bare repositories in the store,
# cloned over file://, so the script runs the way a provisioning unit
# runs it once the network is there. `dir` is relative because the
# script treats it as opaque and each case gets a directory of its own.
{ pkgs }:
let
  origin =
    variant: extra:
    pkgs.runCommand "nixhold-check-origin-${variant}" { nativeBuildInputs = [ pkgs.git ]; } ''
      export HOME=$PWD
      git init -q -b main src
      cd src
      printf 'fixture\n' >README
      ${extra}
      git add -A
      git -c user.name=fixture -c user.email=fixture@example.invalid commit -qm init
      cd ..
      git clone -q --bare src $out
    '';

  tracked = origin "tracked" "printf 'use flake\\n' >.envrc";
  untracked = origin "untracked" "";

  script =
    variant: url:
    import ../modules/repositories/checkout.nix {
      inherit pkgs;
      name = "check-${variant}";
      url = "file://${url}";
      dir = "checkout";
    };
in
pkgs.runCommand "nixhold-repositories-script" { nativeBuildInputs = [ pkgs.git ]; } ''
  export HOME=$PWD/home
  mkdir -p "$HOME"
  # The origins are store paths, owned by root and read by the build
  # user; git refuses a repository it does not own without this.
  git config --global --add safe.directory '*'

  mkdir tracked && cd tracked
  ${script "tracked" tracked}
  if [ "$(cat checkout/.envrc)" != "use flake" ]; then
    echo "the repository's own .envrc was overwritten:" >&2
    cat checkout/.envrc >&2
    exit 1
  fi
  if grep -qxF '.envrc' checkout/.git/info/exclude 2>/dev/null; then
    echo "a tracked .envrc was excluded in .git/info/exclude" >&2
    exit 1
  fi
  if [ -n "$(git -C checkout status --porcelain)" ]; then
    echo "the checkout is dirty after provisioning:" >&2
    git -C checkout status --porcelain >&2
    exit 1
  fi
  cd ..

  mkdir untracked && cd untracked
  ${script "untracked" untracked}
  grep -q 'managed by nixhold' checkout/.envrc || {
    echo "no managed .envrc was written for a repository that has none" >&2
    exit 1
  }
  grep -qxF '.envrc' checkout/.git/info/exclude || {
    echo "the managed .envrc was not added to .git/info/exclude" >&2
    exit 1
  }
  if [ -n "$(git -C checkout status --porcelain)" ]; then
    echo "the managed .envrc shows up as a change:" >&2
    git -C checkout status --porcelain >&2
    exit 1
  fi
  # The .envrc is the done marker: a second run is a no-op.
  ${script "untracked" untracked}
  cd ..

  touch $out
''
