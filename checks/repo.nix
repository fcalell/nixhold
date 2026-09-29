# `nixhold repo` (ARCHITECTURE "nixhold repo"), run through the
# dispatcher against bare repositories standing in for the forges: the
# fleet checkout and the baked list are the set, a declared checkout
# not on disk is `missing`, status reads every one, pull fast-forwards
# the ones behind and refuses a diverged one without stopping the
# rest, push sends the ones ahead and refuses a diverged one, an
# unreachable forge fails the verb, and the draft hook reads the staged
# change in the checkout. No terminal here, so no offer is made.
{ pkgs }:
pkgs.runCommand "nixhold-repo"
  {
    nativeBuildInputs = [
      pkgs.bash
      pkgs.git
    ];
  }
  ''
    export HOME=$PWD/home TMPDIR=$PWD/tmp NIXHOLD_INSTALLER_MARKER=$PWD/no-marker
    mkdir -p "$HOME" "$TMPDIR"
    unset XDG_RUNTIME_DIR GIT_SSH_COMMAND NIXHOLD_CLONE_KEY_FILE
    git config --global user.name t
    git config --global user.email t@t
    git config --global init.defaultBranch main

    fail() { echo "$1" >&2; exit 1; }
    commit() { echo "$2" >"$1/$2"; git -C "$1" add "$2"; git -C "$1" commit -qm "$2"; }
    head() { git -C "$1" rev-parse HEAD; }
    forge() {
      git init -q --bare "forge/$1.git"
      git clone -q "forge/$1.git" "work/$1" 2>/dev/null
      commit "work/$1" init
      git -C "work/$1" push -q -u origin main
      git clone -q "forge/$1.git" "elsewhere/$1"
    }
    nixhold() { bash ${../cli}/nixhold.sh repo "$@"; }

    mkdir forge work elsewhere
    forge fleet
    touch work/fleet/flake.nix
    forge alpha
    forge beta
    export NIXHOLD_FLEET=$PWD/work/fleet
    export NIXHOLD_REPOSITORIES="alpha	$PWD/work/alpha
    beta	$PWD/work/beta
    gamma	$PWD/work/gamma
    "

    # alpha behind, beta ahead, gamma declared and not cloned.
    commit elsewhere/alpha a1
    git -C elsewhere/alpha push -q
    commit work/beta b1

    nixhold status >out || fail "status failed: $(cat out)"
    sed -n 4p out | grep -Eq '│ fleet +│ main +│ up to date ' || fail "the fleet is not the first checkout: $(cat out)"
    grep -Eq '│ alpha +│ main +│ behind 1 ' out || fail "alpha is not behind by one: $(cat out)"
    grep -Eq '│ beta +│ main +│ ahead 1 ' out || fail "beta is not ahead by one: $(cat out)"
    grep -Eq '│ gamma +│ - +│ missing' out || fail "gamma is not missing: $(cat out)"

    nixhold pull 2>err || fail "pull failed: $(cat err)"
    [ "$(head work/alpha)" = "$(head elsewhere/alpha)" ] || fail "pull did not fast-forward alpha"
    [ -d work/gamma ] && fail "pull cloned a missing checkout"

    # alpha diverged: refused, left where it was, and beta still pushes.
    commit elsewhere/alpha a2
    git -C elsewhere/alpha push -q
    commit work/alpha a3
    before=$(head work/alpha)
    if nixhold pull 2>err; then fail "pull accepted a diverged checkout"; fi
    grep -q "not pulled: alpha" err || fail "pull did not name the diverged checkout: $(cat err)"
    [ "$(head work/alpha)" = "$before" ] || fail "pull moved a diverged checkout"

    if nixhold push 2>err; then fail "push accepted a diverged checkout"; fi
    grep -q "not pushed: alpha" err || fail "push did not name the diverged checkout: $(cat err)"
    [ "$(git -C forge/beta.git rev-parse main)" = "$(head work/beta)" ] || fail "push did not send beta"
    [ "$(git -C forge/alpha.git rev-parse main)" != "$before" ] || fail "push forced a diverged checkout"

    # A forge out of reach fails status and marks its line.
    git -C work/beta remote set-url origin "$PWD/gone.git"
    if nixhold status >out 2>/dev/null; then fail "status accepted an unreachable forge"; fi
    grep -Eq '│ beta .*unreachable' out || fail "status did not mark beta unreachable: $(cat out)"

    # The draft hook: run in the checkout, the staged change on stdin.
    echo change >work/fleet/flake.nix
    git -C work/fleet add flake.nix
    cat >hook <<'EOF'
    #!/bin/sh
    pwd >"$HOOK_OUT/cwd"
    cat >"$HOOK_OUT/stdin"
    echo "fleet: drafted"
    EOF
    chmod +x hook
    draft() {
      bash -c '
        NIXHOLD_LIB_ROOT=${../cli}
        . "$NIXHOLD_LIB_ROOT/lib/run.sh"
        . "$NIXHOLD_LIB_ROOT/lib/checkout.sh"
        nh_checkout_draft "$1"
      ' draft "$@"
    }
    mkdir hookout
    [ -z "$(draft work/fleet 2>/dev/null)" ] || fail "no hook still drafted a message"
    msg=$(HOOK_OUT=$PWD/hookout NIXHOLD_REPO_DRAFT=$PWD/hook draft work/fleet 2>/dev/null)
    [ "$msg" = "fleet: drafted" ] || fail "the draft is not the hook's output: $msg"
    [ "$(cat hookout/cwd)" = "$PWD/work/fleet" ] || fail "the hook did not run in the checkout"
    grep -q '^+change' hookout/stdin || fail "the hook did not read the staged diff"

    touch $out
  ''
