# The checkout meeting the forge (nh_checkout_sync; ARCHITECTURE "Where
# a host is built"), run for real against a bare repository standing
# in for the forge: a checkout behind it fast-forwards, one ahead is
# left alone, a diverged one and a dirty one are refused, a dirty one
# fast-forwards under --allow-dirty, and an unreachable forge stops.
{ pkgs }:
pkgs.runCommand "nixhold-fleet-sync"
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

    sync() {
      bash -c '
        NIXHOLD_LIB_ROOT=${../cli}
        . "$NIXHOLD_LIB_ROOT/lib/run.sh"
        . "$NIXHOLD_LIB_ROOT/lib/prompt.sh"
        . "$NIXHOLD_LIB_ROOT/lib/fleet.sh"
        . "$NIXHOLD_LIB_ROOT/lib/checkout.sh"
        nh_checkout_sync "$@"
      ' sync "$@"
    }
    fail() { echo "$1" >&2; exit 1; }
    commit() { echo "$2" >"$1/$2"; git -C "$1" add "$2"; git -C "$1" commit -qm "$2"; }
    head() { git -C "$1" rev-parse HEAD; }

    git init -q --bare forge.git
    git clone -q forge.git here 2>/dev/null
    commit here a
    git -C here push -q -u origin main
    git clone -q forge.git elsewhere

    # In step with the forge: nothing moves.
    sync here || fail "an up-to-date checkout was refused"

    # The forge moved on from another machine: fast-forward.
    commit elsewhere b
    git -C elsewhere push -q
    sync here || fail "a checkout behind the forge was refused"
    [ "$(head here)" = "$(head elsewhere)" ] || fail "a checkout behind the forge did not fast-forward"

    # Ahead only: left for the push.
    commit here c
    before=$(head here)
    sync here || fail "a checkout ahead of the forge was refused"
    [ "$(head here)" = "$before" ] || fail "a checkout ahead of the forge moved"

    # Diverged: refused, both sides named, nothing moves.
    git -C elsewhere pull -q
    commit elsewhere d
    git -C elsewhere push -q
    git -C here reset -q --hard HEAD~1
    commit here e
    before=$(head here)
    if sync here 2>err; then fail "a diverged checkout was accepted"; fi
    grep -q " e$" err && grep -q " d$" err || fail "the refusal did not name both sides: $(cat err)"
    [ "$(head here)" = "$before" ] || fail "a diverged checkout moved"
    git -C here reset -q --hard origin/main

    # Dirty and behind: refused, unless allowed, then fast-forwarded
    # with the edit kept.
    commit elsewhere f
    git -C elsewhere push -q
    echo edit >here/a
    if sync here 2>/dev/null; then fail "a dirty checkout was accepted"; fi
    sync here --allow-dirty || fail "--allow-dirty refused a dirty checkout"
    [ -f here/f ] || fail "--allow-dirty did not fast-forward"
    [ "$(cat here/a)" = edit ] || fail "the fast-forward lost the local edit"
    git -C here checkout -q -- a

    # The forge unreachable: stop.
    git -C here remote set-url origin "$PWD/gone.git"
    if sync here 2>/dev/null; then fail "an unreachable forge was accepted"; fi

    touch $out
  ''
