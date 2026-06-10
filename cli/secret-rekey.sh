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

  (
    set -euo pipefail
    # One private workdir for identity + per-secret temp files; the
    # trap removes it whole, so a mid-loop failure can't leak
    # decrypted plaintext into $TMPDIR.
    workdir="$(mktemp -d -t nixhold-rekey.XXXXXX)"
    chmod 700 "$workdir"
    trap 'rm -rf "$workdir"' EXIT
    idfile="$workdir/identity"
    nh_unwrap_identity "$idfile"

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
        printf '%s' "$json" | jq -r --arg n "$name" '.[$n].recipients[]' >"$rfile"
        if [ ! -s "$rfile" ]; then
          nh_warn "hosts/$host/$name.age has no recipients (missing operator/host pubkeys?) — NOT rekeyed"
          failed=1
          continue
        fi
        age -d -i "$idfile" -o "$tmp" "$target"
        # Encrypt to a sibling temp + rename so a failure can't leave
        # the committed ciphertext truncated.
        age -R "$rfile" -o "$target.tmp" "$tmp"
        mv "$target.tmp" "$target"
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
