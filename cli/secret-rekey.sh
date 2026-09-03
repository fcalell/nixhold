# nixhold secret rekey
#
# Re-encrypts every existing secret to its current recipient set —
# run after committing a new host key (rotate-key) or changing the
# recipient model. Walks every host's declared secrets, decrypts each
# present .age with the operator identity, and re-encrypts.

cmd_secret_rekey() {
  nh_require_cmd age jq nix

  local sdir
  sdir="$(nh_worktree_secrets_dir)" || return 2

  # Skip the passphrase prompt entirely when there's no ciphertext to
  # re-encrypt.
  local has=0 f
  for f in "$sdir"/hosts/*/*.age; do
    [ -e "$f" ] && {
      has=1
      break
    }
  done
  if [ "$has" -eq 0 ]; then
    nh_info "no secrets to rekey"
    return 0
  fi

  # errexit is IGNORED throughout this subshell whenever the caller
  # tests our exit code — `host rotate-key` runs `if ! cmd_secret_rekey`
  # and `host key` runs `cmd_secret_rekey || …`, which disables -e
  # for the whole callee (re-setting it here changes nothing). Every
  # failure that must stop or mark the run is therefore checked
  # explicitly below; `set -e` remains only for direct invocation.
  (
    set -euo pipefail
    # One private workdir for identity + per-secret temp files, under
    # the process scratch root the dispatcher wipes on
    # EXIT/INT/TERM/HUP — so neither a mid-loop failure nor a Ctrl-C at
    # the passphrase prompt leaks the identity or decrypted plaintext
    # into $TMPDIR. (A trap installed here would not fire on Ctrl-C:
    # bash resets trapped signals inside a subshell.)
    workdir="$(nh_tmpdir rekey)" || {
      nh_err "could not create a private workdir — nothing was rekeyed"
      exit 2
    }
    idfile="$workdir/identity"
    # Ahead of any per-secret work: with no identity nothing can be
    # decrypted, and a caller that rolls back (rotate-key) must see the
    # failure while every ciphertext is still untouched.
    nh_unwrap_identity "$idfile" || {
      nh_err "operator identity unavailable — no secret was rekeyed"
      exit 1
    }

    local count=0 failed=0 host platform json name target rfile tmp
    while IFS= read -r host; do
      [ -n "$host" ] || continue
      # A skipped host means its secrets stay encrypted to a STALE
      # recipient set — never silent, and the verb fails overall.
      if ! platform="$(nh_host_platform "$host")"; then
        nh_warn "skipping $host — platform probe failed; its secrets were NOT rekeyed"
        failed=1
        continue
      fi
      if ! json="$(nh_host_eval "$host" "$platform" nixhold.secrets 2>/dev/null)"; then
        nh_warn "skipping $host — eval of nixhold.secrets failed; its secrets were NOT rekeyed"
        failed=1
        continue
      fi
      while IFS= read -r name; do
        [ -n "$name" ] || continue
        target="$sdir/hosts/$host/$name.age"
        [ -e "$target" ] || continue
        rfile="$workdir/recipients"
        tmp="$workdir/plain"
        # Shared validation: a recipient set missing the operator or
        # the owning host is refused here, so a rekey can never quietly
        # re-encrypt a host's secrets to the operator alone.
        if ! nh_recipients_file "$json" "$host" "$name" "$rfile"; then
          nh_warn "hosts/$host/$name.age NOT rekeyed — see the error above"
          failed=1
          continue
        fi
        if ! age -d -i "$idfile" -o "$tmp" "$target"; then
          rm -f "$tmp"
          nh_warn "hosts/$host/$name.age is not decryptable by the operator identity — NOT rekeyed"
          failed=1
          continue
        fi
        # Encrypt to a sibling temp + rename so a failure can't leave
        # the committed ciphertext truncated.
        if ! age -R "$rfile" -o "$target.tmp" "$tmp"; then
          rm -f "$target.tmp" "$tmp"
          nh_warn "re-encryption of hosts/$host/$name.age failed — the original is untouched"
          failed=1
          continue
        fi
        if ! mv "$target.tmp" "$target"; then
          rm -f "$target.tmp" "$tmp"
          nh_warn "could not replace hosts/$host/$name.age — the original is untouched"
          failed=1
          continue
        fi
        # Plaintext in hand: refresh the committed identity pubkey
        # (also the backfill path for fleets predating identity.pub).
        if [ "$(printf '%s' "$json" | jq -r --arg n "$name" '.[$n].sshIdentity // false')" = "true" ]; then
          nh_commit_identity_pub "$host" "$tmp" || true
        fi
        rm -f "$tmp"
        count=$((count + 1))
        nh_info "rekeyed hosts/$host/$name.age"
      done < <(printf '%s' "$json" | jq -r 'keys[]')
    done < <(nh_all_hosts)

    if [ "$failed" -ne 0 ]; then
      nh_err "rekeyed $count secret(s), but some were skipped — fix the warnings above and re-run"
      exit 1
    fi
    nh_ok "rekeyed $count secret(s)"
  )
}
