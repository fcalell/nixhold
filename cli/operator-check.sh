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
# The passphrase route is opened with the string the CLI reads itself,
# so the same string is then proved against every `operatorPassphrase`
# ciphertext the fleet declares (ARCHITECTURE "One passphrase"): the
# console password and the wrap are two artifacts of one string, and
# nothing but this verb can see them drift.
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
  The passphrase is also proved against the hash every
  `operatorPassphrase` secret holds (the NixOS console password).
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
  nh_require_cmd age age-plugin-batchpass mkpasswd jq nix || return 1

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
      nh_operator_check_hashes || failed=1
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

# nh_operator_check_hashes — the coupling's proof: every
# `operatorPassphrase` ciphertext the fleet declares, opened with the
# identity the held passphrase just unwrapped, hashes that same string.
# One check per ciphertext (fleet scope makes it one), a host that does
# not evaluate is named and skipped.
nh_operator_check_hashes() {
  local idfile sdir d line h platform json name scope target seen=" " rc=0
  idfile="$(nh_passphrase_identity_file)" || return 1
  sdir="$(nh_worktree_secrets_dir)" || return 1
  d="$(nh_tmpdir operator-check-hash)" || return 1
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    h="${line%% *}"
    platform="${line##* }"
    json="$(nh_host_secrets "$h" "$platform" 2>/dev/null)" || {
      nh_warn "$h does not evaluate — its passphrase hash is unproven"
      continue
    }
    while IFS=$'\t' read -r name scope; do
      [ -n "$name" ] || continue
      target="$(nh_secret_file "$sdir" "$h" "$name" "$scope")"
      case "$seen" in *" $target "*) continue ;; esac
      seen="$seen$target "
      if [ ! -f "$target" ]; then
        nh_warn "$name is declared on $h with no ciphertext at $target — 'nixhold secret edit $h $name' mints it"
        continue
      fi
      if ! age -d -i "$idfile" -o "$d/hash" "$target"; then
        rm -f "$d/hash"
        nh_err "$target: not opened by the operator identity"
        rc=1
        continue
      fi
      if nh_passphrase_verify "$d/hash"; then
        nh_ok "passphrase hash ($target): the same string"
      else
        nh_err "passphrase hash ($target): a different string than the one that opens the operator identity — 'nixhold secret edit $name' writes both from one prompt"
        rc=1
      fi
      rm -f "$d/hash"
    done < <(printf '%s' "$json" | jq -r '
      to_entries[] | select(.value.operatorPassphrase == true)
      | [ .key, (.value.scope // "host") ] | @tsv')
  done < <(nh_hosts)
  return "$rc"
}
