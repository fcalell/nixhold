# nixhold operator remove <line-or-substring>
#
# The reverse of `operator enrol`: drop an operator seat's lines from
# the two files that grant it, rekey what the change moved, commit.
#
# The argument is a whole line or any substring unique within a file.
# The label an enrolled token carries as its SSH comment matches both
# of its lines at once, which is the usual way to retire one. A
# substring matching two lines of the same file is refused with the
# candidates rather than guessed at.
#
# Which half was removed decides whether a rekey follows:
# keys/operator.pub is an age recipient set, so a line leaving it means
# every ciphertext is re-encrypted without it. keys/login.pub is ssh,
# where nothing is encrypted to anything and the change lands when each
# host activates.
#
# Nothing here reaches the token. A removed recipient stops being
# written to; the credential on the device is inert, not revoked.

cmd_operator_remove() {
  local needle="" yes=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --yes)
        yes=1
        shift
        ;;
      -h | --help)
        cat <<'EOF'
Usage: nixhold operator remove <line-or-substring> [--yes]

  Removes one operator age recipient from keys/operator.pub and/or one
  SSH key from keys/login.pub, whichever the argument matches, then
  re-encrypts every ciphertext to what is left and commits.
EOF
        return 0
        ;;
      -*)
        nh_err "unknown arg: $1"
        return 1
        ;;
      *)
        if [ -n "$needle" ]; then
          nh_err "unexpected argument: $1 ('operator remove' takes one line or substring)"
          return 1
        fi
        needle="$1"
        shift
        ;;
    esac
  done
  if [ -z "$needle" ]; then
    nh_err "usage: nixhold operator remove <line-or-substring>, naming the age recipient, the SSH key line, or the label both carry (keys/login.pub and keys/operator.pub list what is enrolled)"
    return 1
  fi
  nh_require_cmd age jq nix || return 1

  local root rcpt login
  root="$(nh_fleet_root)" || return 2
  rcpt="$(nh_operator_recipient_path)" || return 2
  login="$(nh_login_pub_file)" || return 2

  local op_line login_line
  op_line="$(nh_operator_remove_match "$rcpt" "$needle")" || return 1
  login_line="$(nh_operator_remove_match "$login" "$needle")" || return 1
  if [ -z "$op_line" ] && [ -z "$login_line" ]; then
    nh_err "no line in $rcpt or $login contains '$needle'"
    return 1
  fi

  # The fleet is left with a route and with someone who may log in, or
  # the removal does not happen. An empty recipient set is a fleet
  # nothing can encrypt to, a wrapped identity whose recipient line is
  # gone included, and an empty login list is an ISO that boots
  # unreachable.
  if [ -n "$op_line" ] && [ "$(nh_operator_remove_count "$rcpt")" -le 1 ]; then
    nh_err "that is the last recipient in $rcpt, and removing it leaves the fleet with no operator route at all. Enrol the replacement seat first ('nixhold operator enrol', or a passphrase identity at nixhold.layout.ageIdentityWrapped)"
    return 1
  fi
  if [ -n "$login_line" ] && [ "$(nh_operator_remove_count "$login")" -le 1 ]; then
    nh_err "that is the last key in $login, and removing it means no host authorizes anyone and an ISO built from it boots unreachable. Add the replacement key first"
    return 1
  fi

  nh_info "removing:"
  [ -z "$op_line" ] || nh_info "  $rcpt: $op_line"
  [ -z "$login_line" ] || nh_info "  $login: $login_line"
  if [ -n "$op_line" ]; then
    nh_info "then re-encrypting every ciphertext to the recipients that are left"
  fi
  if [ "$yes" -ne 1 ] && nh_tty && ! nh_prompt_confirm "Remove the line(s) above?"; then
    nh_info "aborted, nothing was removed"
    return 0
  fi

  local changed=()
  if [ -n "$op_line" ]; then
    nh_operator_remove_line "$rcpt" "$op_line" || return 1
    changed+=("$rcpt")
  fi
  if [ -n "$login_line" ]; then
    nh_operator_remove_line "$login" "$login_line" || return 1
    changed+=("$login")
  fi
  nh_stage_for_eval "$root" "${changed[@]}"

  if [ -n "$op_line" ]; then
    # The rekey carries the commit, so the recipient that left and the
    # ciphertexts it can no longer open move together.
    # shellcheck source=secret-rekey.sh
    . "$NIXHOLD_LIB_ROOT/secret-rekey.sh"
    cmd_secret_rekey --quiet --message "operator: remove the seat matching '$needle'" || {
      nh_err "the line is out of $rcpt but some ciphertexts still carry it: fix the errors above and re-run 'nixhold secret rekey'"
      return 1
    }
  else
    nh_info "no rekey: keys/login.pub is ssh, and no age recipient set moved"
    nh_commit_paths "$root" "operator: remove the login key matching '$needle'" "$login"
  fi

  nh_ok "removed"
  nh_info "next: nixhold deploy --all, since a host keeps the old login list until it activates"
}

# nh_operator_remove_match <file> <needle> — the ONE line of <file>
# containing <needle>, or nothing at all when it contains none.
# Non-zero, with the candidates, when it contains several: a substring
# that names two seats is the operator's to narrow, never this verb's
# to pick between.
nh_operator_remove_match() {
  local f="$1" needle="$2" hits n
  hits="$(nh_pubkey_lines "$f" 2>/dev/null | grep -F -- "$needle" || true)"
  [ -n "$hits" ] || return 0
  n="$(printf '%s\n' "$hits" | wc -l)"
  if [ "$n" -gt 1 ]; then
    nh_err "'$needle' matches $n lines in $f:"
    printf '%s\n' "$hits" >&2
    return 1
  fi
  printf '%s' "$hits"
}

# nh_operator_remove_count <file> — how many key lines it holds.
nh_operator_remove_count() {
  nh_pubkey_lines "$1" 2>/dev/null | wc -l || true
}

# nh_operator_remove_line <file> <line> — rewrite <file> without that
# one line, keeping the comments and blank lines around it. A line the
# rewrite did not actually remove (trailing whitespace, a CRLF file) is
# an error rather than a silent success.
nh_operator_remove_line() {
  local f="$1" line="$2"
  if ! line="$line" awk '{ l = $0; sub(/\r$/, "", l); if (l != ENVIRON["line"]) print }' "$f" >"$f.tmp"; then
    rm -f "$f.tmp"
    nh_err "could not rewrite $f, which is untouched"
    return 1
  fi
  if ! mv "$f.tmp" "$f"; then
    rm -f "$f.tmp"
    nh_err "could not replace $f"
    return 1
  fi
  chmod 0644 "$f"
  if grep -qxF -- "$line" "$f"; then
    nh_err "$f still holds that line after the rewrite: edit it by hand"
    return 1
  fi
}
