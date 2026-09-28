# The staging step of `host install` (nh_install_stage_tree) run for
# real against a stand-in for /mnt: the staged host key and fleet key
# land with their modes, and the root they land in keeps its own.
# nixos-install refuses a root that is not world-readable, and the
# archive's `.` is the 0700 scratch dir the tree was staged in.
{ pkgs }:
pkgs.runCommand "nixhold-stage-tree"
  {
    nativeBuildInputs = [
      pkgs.bash
      pkgs.gnutar
    ];
  }
  ''
    export HOME=$PWD/home TMPDIR=$PWD/tmp
    mkdir -p "$HOME" "$TMPDIR" target
    chmod 0755 target
    unset XDG_RUNTIME_DIR

    bash -c '
      set -e
      umask 077
      NIXHOLD_LIB_ROOT=${../cli}
      . "$NIXHOLD_LIB_ROOT/lib/run.sh"
      . "$NIXHOLD_LIB_ROOT/host-install.sh"
      # /mnt, redirected to the stand-in; --no-same-owner needs no root.
      nh_sudo() { local a=("''${@//\/mnt/'"$PWD"'/target}"); "''${a[@]}"; }
      extra="$(nh_tmpdir extra-files)"
      install -d -m 0755 "$extra/etc" "$extra/etc/ssh" "$extra/etc/nixhold"
      install -m 0600 /dev/null "$extra/etc/ssh/ssh_host_ed25519_key"
      install -m 0400 /dev/null "$extra/etc/nixhold/fleet.key"
      nh_install_stage_tree "" "$extra"
    '

    fail() { echo "$1" >&2; exit 1; }
    mode() { stat -c %a "$1"; }
    [ "$(mode target)" = 755 ] || fail "the target root became $(mode target)"
    [ "$(mode target/etc)" = 755 ] || fail "etc is $(mode target/etc)"
    [ "$(mode target/etc/ssh)" = 755 ] || fail "etc/ssh is $(mode target/etc/ssh)"
    [ "$(mode target/etc/ssh/ssh_host_ed25519_key)" = 600 ] || fail "the host key is $(mode target/etc/ssh/ssh_host_ed25519_key)"
    [ "$(mode target/etc/nixhold/fleet.key)" = 400 ] || fail "the fleet key is $(mode target/etc/nixhold/fleet.key)"
    touch $out
  ''
