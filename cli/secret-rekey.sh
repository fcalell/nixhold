# nixhold secret rekey
#
# Re-encrypts everything this fleet holds to the CURRENT keys:
#   secrets/**.age      → every operator recipient line + keys/fleet.pub
#   keys/fleet.key.age  → the operator recipient lines alone
#
# The recipient set does not vary per host and does not vary per
# secret, so this verb is needed in exactly two situations: the
# operator's recipients changed (a token enrolled, a seat retired), and
# the fleet key changed (`secret rotate`, which calls this). Adding or
# removing a host never needs it.
#
# It is also the MIGRATION path for a fleet that predates the fleet
# key: keys/fleet.key.age is minted when missing, every ciphertext is
# opened over the operator's seat and re-encrypted to it, and
# keys/login.pub is filled in from the `identity` secret when the fleet
# authorizes nobody yet. Nothing is deployed here — until `nixhold
# deploy` puts /etc/nixhold/fleet.key on a host, that host cannot
# decrypt, so do not reboot one in between.
#
# The walk reads the FILESYSTEM, not the eval: a ciphertext whose
# declaration was removed is still a file encrypted to the old key, and
# leaving it behind is how a fleet ends up with something nobody can
# open.
#
# The route is picked with --bulk: one passphrase prompt for the whole
# walk beats one token touch per file, so a fleet holding both prefers
# the passphrase here (single-file verbs still prefer the token).

cmd_secret_rekey() {
  local quiet=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --quiet)
        quiet=1
        shift
        ;;
      -h | --help)
        echo "Usage: nixhold secret rekey"
        return 0
        ;;
      *)
        nh_err "unknown arg: $1"
        return 1
        ;;
    esac
  done
  nh_require_cmd age age-keygen jq nix

  local root keys_dir
  root="$(nh_fleet_root)" || return 2
  keys_dir="$(nh_worktree_keys_dir)" || return 2

  # The fleet key first: it is what everything below is encrypted TO,
  # and a fleet that has none (the migration case) gets one here. Its
  # own re-wrap is skipped when this call just wrote it — a freshly
  # minted key is already sealed to the current recipients.
  nh_probe_recipient_inputs
  local had_key=0
  [ -f "$(nh_fleet_key_file)" ] && had_key=1
  nh_fleet_key_ensure || return 1

  local ciphertexts
  ciphertexts="$(nh_secret_ciphertexts)" || return 2

  # Ahead of any per-file work, so the chosen route is the one the
  # whole walk uses: with no way into the ciphertexts nothing can be
  # decrypted, and the operator must learn that while every one of them
  # is still untouched. A fleet with nothing to open skips it.
  if [ "$had_key" -eq 1 ] || [ -n "$ciphertexts" ]; then
    nh_age_route_check "this fleet's secrets" --bulk || {
      nh_err "no secret was rekeyed"
      return 1
    }
  fi

  local rc=0 count=0 failed=0 rekeyed=() workdir rfile target
  workdir="$(nh_tmpdir rekey)" || return 2
  rfile="$workdir/recipients"
  nh_recipients_file "$rfile" || return 1

  while IFS= read -r target; do
    [ -n "$target" ] || continue
    if nh_secret_reencrypt "$target" "$rfile" "$workdir"; then
      count=$((count + 1))
      rekeyed+=("$target")
    else
      failed=1
    fi
  done <<<"$ciphertexts"

  # The fleet key's own wrapping: encrypted to the operator recipients
  # and to nothing else, so an operator whose recipient list changed
  # can still open it.
  if [ "$had_key" -eq 1 ]; then
    nh_rekey_fleet_key || failed=1
  fi

  if [ "$failed" -ne 0 ]; then
    nh_err "rekeyed $count secret(s), but some were skipped — fix the warnings above and re-run"
    rc=1
  elif [ "$quiet" -eq 0 ]; then
    nh_ok "rekeyed $count secret(s) to the operator recipients + $(nh_fleet_pub_line)"
  fi

  local commit=("$keys_dir/fleet.key.age" "$keys_dir/fleet.pub" "$keys_dir/login.pub")
  [ "${#rekeyed[@]}" -eq 0 ] || commit+=("${rekeyed[@]}")
  nh_commit_paths "$root" "secrets: rekey to the fleet key" "${commit[@]}"
  [ "$rc" -eq 0 ] || return "$rc"
  [ "$quiet" -eq 1 ] || nh_info "next: nixhold deploy — until a host has /etc/nixhold/fleet.key it decrypts nothing"
}

# nh_rekey_fleet_key — re-wrap keys/fleet.key.age to the operator
# recipient lines as they are now. The one ciphertext the fleet key is
# NOT a recipient of: it is what the operator hands to the hosts, so
# only the operator's own seats may open it.
nh_rekey_fleet_key() {
  local key rcpt plain
  key="$(nh_fleet_key_file)" || return 1
  [ -f "$key" ] || return 0
  rcpt="$(nh_operator_recipient_file)" || return 1
  plain="$(nh_fleet_key_plain)" || return 1
  if ! age -R "$rcpt" -o "$key.tmp" "$plain"; then
    rm -f "$key.tmp"
    nh_warn "could not re-wrap $key to the current operator recipients — the original is untouched"
    return 1
  fi
  if ! mv "$key.tmp" "$key"; then
    rm -f "$key.tmp"
    nh_warn "could not replace $key — the original is untouched"
    return 1
  fi
  chmod 0644 "$key"
  nh_stage_for_eval "$(nh_fleet_root)" "$key"
}
