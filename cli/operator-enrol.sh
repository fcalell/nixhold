# nixhold operator enrol [<label>]
#
# Enrols a FIDO2 token as an operator seat. A seat is two credentials
# and they are minted together, because either alone is a half-seat:
#
#   keys/login.pub     a resident, PIN-gated ed25519-sk SSH key, what
#                      logs in to every host and to the installer ISO
#   keys/operator.pub  an age1fido2-hmac1… recipient, what opens
#                      keys/fleet.key.age and every secret under it
#
# and one `secret rekey` behind them, in the same commit: a recipient
# line with no rekey is a route the fleet advertises and no ciphertext
# opens, and a login line appended on one machine and never deployed is
# a token that opens nothing.
#
# What stays the operator's: setting the token's PIN, the touches, and
# registering the SSH key on the forge. The private half of that key is
# a HANDLE, not a key. The secret never leaves the token and
# `ssh-keygen -K` writes the handle again on another machine, so it
# lives in ~/.ssh and never in the repo.

cmd_operator_enrol() {
  local label=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h | --help)
        cat <<'EOF'
Usage: nixhold operator enrol [<label>]

  Mints this FIDO2 token's two credentials and commits both: a
  resident ed25519-sk SSH key into keys/login.pub and an
  age1fido2-hmac1… recipient into keys/operator.pub, then re-encrypts
  every ciphertext to the new recipient list.

  <label> names the key and its handle in ~/.ssh (default: the next
  free index).
EOF
        return 0
        ;;
      -*)
        nh_err "unknown arg: $1"
        return 1
        ;;
      *)
        if [ -n "$label" ]; then
          nh_err "unexpected argument: $1 ('operator enrol' takes one label)"
          return 1
        fi
        label="$1"
        shift
        ;;
    esac
  done
  nh_require_cmd age jq nix ssh-keygen fido2-token "$NIXHOLD_AGE_PLUGIN" || return 1

  # Both credentials come off the device, so its absence is the first
  # thing to say, not the third prompt to hang on.
  if [ -z "$(fido2-token -L 2>/dev/null)" ]; then
    nh_err "no FIDO2 token is plugged in (fido2-token -L lists none), and enrolling one needs the device present. The fleet's other route is the passphrase-wrapped identity at nixhold.layout.ageIdentityWrapped, which 'nixhold host add' generates on a fleet that holds neither"
    return 1
  fi
  if [ -z "${HOME:-}" ]; then
    nh_err "\$HOME is unset, so the resident key's handle has nowhere to live"
    return 1
  fi

  local root rcpt login
  root="$(nh_fleet_root)" || return 2
  rcpt="$(nh_operator_recipient_path)" || return 2
  login="$(nh_login_pub_file)" || return 2

  [ -n "$label" ] || label="$(nh_operator_enrol_next_label "$login")"
  case "$label" in
    *[!A-Za-z0-9._-]*)
      nh_err "label '$label': letters, digits, '.', '_' and '-' only, since it names a file in ~/.ssh and the key's comment"
      return 1
      ;;
  esac

  local sshkey="$HOME/.ssh/id_nixhold_sk_$label"
  if [ -e "$sshkey" ] || [ -e "$sshkey.pub" ]; then
    nh_err "$sshkey already exists: enrol under another label, or move that handle aside first ('ssh-keygen -K' rewrites a resident handle from the token itself)"
    return 1
  fi

  nh_info "enrolling the token plugged in here as '$label':"
  nh_info "  1. ssh-keygen -t ed25519-sk (resident, verify-required) → $sshkey"
  nh_info "  2. $NIXHOLD_AGE_PLUGIN -g → an age1fido2-hmac1… recipient"
  nh_info "  3. the SSH line into $login, the age line into $rcpt"
  nh_info "  4. re-encrypt every ciphertext to the new recipient list, and commit"
  nh_info "the token asks for its PIN and a touch at each step, which is the confirmation"

  nh_operator_enrol_ssh_key "$sshkey" "$label" || return 1

  local recipient
  recipient="$(nh_operator_enrol_recipient "$sshkey")" || return 1

  local sshline
  sshline="$(nh_pubkey_line "$sshkey.pub")" || {
    nh_err "no key line in $sshkey.pub"
    return 1
  }
  case "$sshline" in
    'sk-ssh-ed25519@openssh.com '*) ;;
    *)
      nh_err "$sshkey.pub is a ${sshline%% *} key, not sk-ssh-ed25519@openssh.com: this openssh has no security-key support, so the key it wrote is not backed by the token. Delete it and run the CLI's own openssh"
      return 1
      ;;
  esac

  if nh_pubkey_lines "$login" 2>/dev/null | grep -qxF -- "$sshline"; then
    nh_err "$login already authorizes that SSH key, so nothing was appended"
    return 1
  fi
  if nh_pubkey_lines "$rcpt" 2>/dev/null | grep -qxF -- "$recipient"; then
    nh_err "$rcpt already names that age recipient, so nothing was appended"
    return 1
  fi

  nh_operator_append_line "$login" "$sshline" || return 1
  nh_operator_append_line "$rcpt" "$recipient" || {
    nh_err "the login key reached $login but the recipient did not reach $rcpt: 'nixhold operator remove nixhold-$label' takes that login line back out"
    return 1
  }
  nh_stage_for_eval "$root" "$login" "$rcpt"
  nh_ok "appended the login key to $login and the age recipient to $rcpt"

  # The rekey carries the commit: the two new lines, the fleet key
  # re-wrapped to them, and every ciphertext re-encrypted, as one.
  # shellcheck source=secret-rekey.sh
  . "$NIXHOLD_LIB_ROOT/secret-rekey.sh"
  cmd_secret_rekey --quiet --message "operator: enrol the FIDO2 token '$label'" || {
    nh_err "the new lines are in $rcpt and $login but some ciphertexts were NOT re-encrypted to them: fix the errors above and re-run 'nixhold secret rekey' before deploying"
    return 1
  }

  nh_ok "token '$label' is an operator seat: an SSH login key and an age recipient"
  nh_info "next:"
  nh_info "  1. register $sshkey.pub on the forge, so this key authenticates git over SSH"
  nh_info "  2. nixhold deploy --all, since a host authorizes the old login list until it activates"
  if [ -n "$(nh_layout repoUrl 2>/dev/null | jq -r '. // empty')" ]; then
    nh_info "  3. nixhold iso --flash <device>, because the installer image bakes keys/login.pub for root"
  fi
  nh_info "  on every other machine you use this token from: 'ssh-keygen -K' in ~/.ssh writes the handle again (the key itself never leaves the token)"
}

# nh_operator_enrol_next_label <login.pub> — the next free index. Free
# means both halves are: no handle of that name in ~/.ssh and no key
# already carrying that comment in the login list, so a label never
# names two different tokens across the operator's machines.
nh_operator_enrol_next_label() {
  local login="$1" n=1
  while [ -e "$HOME/.ssh/id_nixhold_sk_$n" ] ||
    nh_pubkey_lines "$login" 2>/dev/null | grep -qE "[[:space:]]nixhold-$n\$"; do
    n=$((n + 1))
  done
  printf '%s' "$n"
}

# nh_operator_enrol_ssh_key <path> <label> — the resident credential
# ssh logs in with. `-O resident` is what makes it recoverable onto
# another machine with `ssh-keygen -K`, `-O verify-required` is what
# makes the PIN part of the login rather than of the enrolment, and
# `-O application=ssh:nixhold` is the credential's name on the token,
# which is how it is told from every other resident key on it.
#
# ssh-keygen asks for the PIN and the touch on the terminal, so nothing
# here redirects anything. A failure can still leave a partial pair
# behind, which the next run would refuse to overwrite.
nh_operator_enrol_ssh_key() {
  local out="$1" label="$2"
  if ! mkdir -p "$HOME/.ssh" || ! chmod 700 "$HOME/.ssh"; then
    nh_err "could not prepare $HOME/.ssh"
    return 1
  fi
  nh_info "generating the resident SSH key (the token asks for its PIN, then a touch)"
  if ! ssh-keygen -t ed25519-sk -O resident -O verify-required \
    -O application=ssh:nixhold -C "nixhold-$label" -f "$out" -N ""; then
    rm -f "$out" "$out.pub"
    nh_err "ssh-keygen minted no ed25519-sk key (wrong PIN, no touch, a token without a PIN set, or an openssh without security-key support), and nothing was written to the fleet"
    return 1
  fi
  nh_ok "resident SSH key at $out (the private half is a handle; the key is on the token)"
}

# nh_operator_enrol_recipient <sshkey> — the age1fido2-hmac1… line, on
# stdout. `-g` is interactive only: it has no flag for either answer,
# so the questions are the operator's and the guidance below is what
# keeps them right.
#
# The "separate identity" question decides the SHAPE of the output, not
# a detail of it. Answered "no" the plugin prints an age1fido2-hmac1…
# recipient the token alone opens; answered "yes" it prints a plain
# age1… recipient plus an identity file to keep, which is a second
# thing to lose and not what this fleet commits. Its prompts go to the
# terminal and the credential to stdout, so capturing one does not eat
# the other.
nh_operator_enrol_recipient() {
  local sshkey="$1" d creds recipient
  d="$(nh_tmpdir enrol)" || return 1
  creds="$d/credential"
  nh_info "generating the age credential: answer YES to \"require a PIN for decryption\" and NO to \"a separate identity\", because the token itself is the identity"
  if ! "$NIXHOLD_AGE_PLUGIN" -g >"$creds"; then
    nh_err "$NIXHOLD_AGE_PLUGIN -g failed, so there is no age recipient. The SSH key at $sshkey is already minted: re-run with the same label after moving it aside, or with another one"
    return 1
  fi
  recipient="$(awk '$1 == "#" && $2 == "public" && $4 ~ /^age1fido2-hmac1/ { print $4; exit }' "$creds")"
  if [ -z "$recipient" ]; then
    nh_err "$NIXHOLD_AGE_PLUGIN -g printed no age1fido2-hmac1… recipient: \"Are you fine with having a separate identity\" has to be answered NO for the token to BE the identity. Re-run after moving $sshkey aside; the credential this attempt left on the token is unused"
    return 1
  fi
  printf '%s' "$recipient"
}
