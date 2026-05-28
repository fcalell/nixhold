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
    idfile="$(mktemp -t nixhold-id.XXXXXX)"
    chmod 600 "$idfile"
    trap 'rm -f "$idfile"' EXIT
    nh_unwrap_identity "$idfile"

    local count=0 host platform json name target rfile tmp
    while IFS= read -r host; do
      [ -n "$host" ] || continue
      platform="$(nh_host_platform "$host")" || continue
      json="$(nh_host_eval "$host" "$platform" nixhold.secrets 2>/dev/null)" || continue
      while IFS= read -r name; do
        [ -n "$name" ] || continue
        target="$sdir/hosts/$host/$name.age"
        [ -e "$target" ] || continue
        rfile="$(mktemp -t nixhold-rcpt.XXXXXX)"
        tmp="$(mktemp -t nixhold-plain.XXXXXX)"
        chmod 600 "$tmp"
        printf '%s' "$json" | jq -r --arg n "$name" '.[$n].recipients[]' >"$rfile"
        age -d -i "$idfile" -o "$tmp" "$target"
        age -R "$rfile" -o "$target" "$tmp"
        rm -f "$rfile" "$tmp"
        count=$((count + 1))
        nh_info "rekeyed hosts/$host/$name.age"
      done < <(printf '%s' "$json" | jq -r 'keys[]')
    done < <(nh_all_hosts)

    nh_ok "rekeyed $count secret(s)"
  )
}
