# The clone key's reach past git (ARCHITECTURE "The clone credential
# is the `identity` key"): a run that holds a clone key exports the
# ssh command naming it, so Nix's own fetch of a private `git+ssh`
# input takes the same key. Sourced from the CLI's libraries with the
# decrypt stubbed: what is under test is which command a run exports
# and which one a remote installer's disko and build are handed, not
# age.
{ pkgs }:
pkgs.runCommand "nixhold-clone-ssh" { nativeBuildInputs = [ pkgs.bash ]; } ''
  export HOME=$PWD/home TMPDIR=$PWD/tmp NIXHOLD_INSTALLER_MARKER=$PWD/no-marker
  mkdir -p "$HOME" "$TMPDIR"
  unset XDG_RUNTIME_DIR GIT_SSH_COMMAND NIXHOLD_CLONE_KEY_FILE NIXHOLD_REEXEC
  : >identity.age

  run() {
    bash -c '
      NIXHOLD_LIB_ROOT=${../cli}
      . "$NIXHOLD_LIB_ROOT/lib/run.sh"
      . "$NIXHOLD_LIB_ROOT/host-install.sh"
      nh_clone_key() { opened=1; : >"$(nh_tmp_root)/clone.key"; printf %s "$(nh_scratch_root_path)/clone.key"; }
      opened=0
      '"$1"'
    '
  }
  fail() { echo "$1" >&2; exit 1; }

  # No clone key: nothing is exported, git and Nix run on ssh config.
  got=$(run 'nh_export_clone_ssh; printf %s "''${GIT_SSH_COMMAND:-}"')
  [ -z "$got" ] || fail "exported with no clone key: $got"

  # A clone key: the command names the scratch path the decrypt writes,
  # without opening it, and a child process (Nix) inherits it.
  got=$(NIXHOLD_CLONE_KEY_FILE=$PWD/identity.age run '
    nh_export_clone_ssh
    [ "$opened" = 0 ] || { echo "opened the key before the clone" >&2; exit 1; }
    want="ssh -i $(nh_scratch_root_path)/clone.key -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
    [ "$(bash -c "printf %s \"\$GIT_SSH_COMMAND\"")" = "$want" ] || { echo "child saw: $GIT_SSH_COMMAND" >&2; exit 1; }
    echo ok')
  [ "$got" = ok ] || fail "the clone key's command did not reach a child"

  # An inherited command is kept: the pinned CLI uses its parent's key.
  got=$(NIXHOLD_CLONE_KEY_FILE=$PWD/identity.age GIT_SSH_COMMAND=parent run '
    nh_export_clone_ssh; printf %s "$GIT_SSH_COMMAND"')
  [ "$got" = parent ] || fail "an inherited command was replaced: $got"

  # A pinned CLI that inherits none opens the key itself, up front.
  got=$(NIXHOLD_CLONE_KEY_FILE=$PWD/identity.age NIXHOLD_REEXEC=1 run '
    nh_export_clone_ssh
    [ "$opened" = 1 ] && [ -f "$(nh_scratch_root_path)/clone.key" ] && echo ok')
  [ "$got" = ok ] || fail "a handed-off CLI did not open the key before its first evaluation"

  # A remote installer: the command names the copy the clone placed,
  # quoted so the installer's shell reads it back as one word.
  got=$(run 'eval "x=$(nh_installer_ssh_command)"; printf %s "$x"')
  want="ssh -i /root/.ssh/nixhold-identity -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
  [ "$got" = "$want" ] || fail "the installer's command reads back as: $got"

  touch $out
''
