# nixhold operator check
#
# Opens keys/fleet.key.age over every route this fleet commits. That
# one ciphertext is what every other one hangs off, so a route that
# opens it opens the fleet, and a recipient line no seat can use is
# invisible until the day it is the only seat left, which is the day it
# cannot be fixed.
#
# Read-only: nothing is written and nothing is committed. One line per
# route, and a non-zero exit when any of them failed or the fleet
# commits none at all.
#
# The token route is ONE check however many age1fido2-hmac1… lines the
# fleet holds: `age -d -j fido2-hmac` decrypts with whichever token is
# plugged in and does not report which line answered. What it proves is
# "the token in this port opens the fleet key"; proving the second one
# is plugging the second one in.

cmd_operator_check() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h | --help)
        cat <<'EOF'
Usage: nixhold operator check

  Opens keys/fleet.key.age over each committed route: the
  passphrase-wrapped identity, and the FIDO2 token that is plugged in.
  Prints one line per route and exits non-zero if any of them fails.
EOF
        return 0
        ;;
      *)
        nh_err "unknown arg: $1"
        return 1
        ;;
    esac
  done
  nh_require_cmd age jq nix || return 1

  local key rcpt d out wrapped tokens routes=0 failed=0
  key="$(nh_fleet_key_file)" || return 2
  rcpt="$(nh_operator_recipient_path)" || return 2
  if [ ! -f "$key" ]; then
    nh_err "no fleet key at $key, so there is no ciphertext to prove a route against ('nixhold secret rekey' mints one)"
    return 1
  fi
  d="$(nh_tmpdir operator-check)" || return 1
  out="$d/fleet.key"
  nh_info "opening $key over every route this fleet commits"

  if wrapped="$(nh_age_wrapped_identity)"; then
    routes=$((routes + 1))
    if nh_operator_route_decrypt passphrase "$key" "$out"; then
      nh_ok "passphrase route ($wrapped): ok"
    else
      nh_err "passphrase route ($wrapped): did not open the fleet key"
      failed=1
    fi
    rm -f "$out"
  fi

  tokens="$(nh_pubkey_lines "$rcpt" 2>/dev/null | grep -c '^age1fido2-hmac1' || true)"
  if [ "$tokens" -gt 0 ]; then
    routes=$((routes + 1))
    if ! nh_age_token_present; then
      nh_err "token route ($tokens recipient line(s) in $rcpt): no token is plugged in, so the route is unproven. Plug one in and re-run"
      failed=1
    elif nh_operator_route_decrypt token "$key" "$out"; then
      nh_ok "token route ($tokens recipient line(s) in $rcpt): ok for the token in this port; the others are proved by plugging them in"
      rm -f "$out"
    else
      nh_err "token route ($tokens recipient line(s) in $rcpt): the plugged-in token did not open the fleet key, so it may be a token this fleet never enrolled"
      failed=1
    fi
  fi

  if [ "$routes" -eq 0 ]; then
    nh_err "this fleet commits no operator route: $rcpt names no age1fido2-hmac1… recipient and this checkout holds no passphrase-wrapped identity, so nothing opens $key"
    return 1
  fi
  [ "$failed" -eq 0 ] || return 1
  nh_ok "every committed route opens the fleet key"
}
