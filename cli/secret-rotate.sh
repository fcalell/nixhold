# nixhold secret rotate [--yes]
#
# Retires the fleet key and puts a new one in its place: mint,
# re-encrypt every ciphertext to it (`secret rekey`), then deploy.
#
# One key reads every secret in this fleet, and every host holds a copy
# of it at /etc/nixhold/fleet.key. So the answer to "a machine left the
# fleet and was not wiped", "a disk went out for RMA", "someone had
# root on a host" is this verb: after it, the copy that machine holds
# opens nothing.
#
# Between the rekey and the deploy the hosts still hold the OLD key and
# the repo holds only new ciphertexts — so a host that reboots in that
# window comes up unable to decrypt. `nixhold deploy` (no names, or one
# at a time) closes it: it compares /etc/nixhold/fleet.pub with
# keys/fleet.pub and installs the new key before it activates anything.
#
# The verb `host rotate-key` used to live next to this one. It is gone:
# a host's SSH key is a machine identity here, not a recipient, so
# replacing one is `nixhold host install` (a re-image mints a fresh
# one) or `nixhold host key <name>` (record what the machine runs).

cmd_secret_rotate() {
  local yes=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --yes)
        yes=1
        shift
        ;;
      -h | --help)
        cat <<'EOF'
Usage: nixhold secret rotate [--yes]

  Mints a new fleet key, re-encrypts every secret to it, and commits.
  Every host keeps decrypting with the old key until 'nixhold deploy'
  installs the new one — deploy right after this.
EOF
        return 0
        ;;
      *)
        nh_err "unknown arg: $1"
        return 1
        ;;
    esac
  done
  nh_require_cmd age age-keygen jq nix

  nh_fleet_root >/dev/null || return 2

  # The route BEFORE the mint: every ciphertext has to be opened with
  # the operator's seat and written back, and a fleet whose new key
  # landed while its secrets stayed on the old one is worse off than
  # one that rotated nothing.
  nh_probe_recipient_inputs
  nh_age_route_check "this fleet's secrets" --bulk || {
    nh_err "nothing was rotated — the fleet key is unchanged"
    return 1
  }

  local old="(none)"
  old="$(nh_fleet_pub_line 2>/dev/null || printf '(none)')"
  nh_warn "rotating the fleet key: every secret is re-encrypted, and every host keeps the OLD key until you deploy"
  nh_info "current: $old"
  if [ "$yes" -ne 1 ] && nh_tty && ! nh_prompt_confirm "Mint a new fleet key and re-encrypt every secret to it?"; then
    nh_info "aborted — the fleet key is unchanged"
    return 0
  fi

  nh_fleet_key_mint || {
    nh_err "no new fleet key was written — nothing changed"
    return 1
  }

  # The rekey commits the new key pair together with the ciphertexts:
  # a commit that moved one without the other would be a fleet nobody
  # can read.
  . "$NIXHOLD_LIB_ROOT/secret-rekey.sh"
  cmd_secret_rekey --quiet || {
    nh_err "the new fleet key is committed but some secrets were NOT re-encrypted to it — fix the errors above and re-run 'nixhold secret rekey' BEFORE deploying"
    return 1
  }

  nh_ok "fleet key rotated: $(nh_fleet_pub_line)"
  nh_info "the old key ($old) opens nothing in this repo any more"
  nh_info "next: nixhold deploy — it installs the new key on each host before activating it"
}
