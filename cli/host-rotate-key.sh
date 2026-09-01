# nixhold host rotate-key <name>
#
# Generates a fresh SSH host keypair for <name>, commits the new
# pubkey under keysDir (so it becomes the host's age recipient), then
# re-encrypts every secret to the rotated recipient set. Used after a
# lost key cache (L10 recovery) or a routine key rotation; follow with
# `nixhold host install <name>` (to ship the new key) or `deploy`.

# nh_unstage_intent <root> <path> — drop an `add --intent-to-add`
# index entry for a file the rollback deleted, so a rolled-back
# rotation leaves no phantom "deleted file" in git status.
nh_unstage_intent() {
  local root="$1" path="$2" rel
  git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  rel="$(git -C "$root" ls-files --full-name --error-unmatch -- "$path" 2>/dev/null)" || return 0
  # Only ever drop an entry this run added: a path that exists in HEAD
  # is committed state, and staging its deletion is not a rollback.
  if git -C "$root" cat-file -e "HEAD:$rel" 2>/dev/null; then
    return 0
  fi
  git -C "$root" rm --cached --force --quiet -- "$path" >/dev/null 2>&1 || true
}

cmd_host_rotate_key() {
  local name="${1:-}"
  if [ -z "$name" ]; then
    nh_err "expected: nixhold host rotate-key <name>"
    return 1
  fi
  nh_require_cmd ssh-keygen age jq nix

  nh_host_platform "$name" >/dev/null || {
    nh_err "host '$name' not found in fleet"
    return 1
  }

  local root cache keys_dir
  root="$(nh_fleet_root)" || return 1
  cache="$NIXHOLD_CACHE_DIR/host-keys/$name"
  keys_dir="$(nh_worktree_keys_dir)"

  if [ -f "$cache/ssh_host_ed25519_key" ] &&
    ! nh_prompt_confirm "Replace the existing cached key for $name? (old ciphertext becomes undecryptable by the old host key)"; then
    nh_info "aborted"
    return 0
  fi

  # Generate the replacement under a temp name. The old key and the
  # committed pubkey are swapped only AFTER the rekey succeeds, so a
  # mid-rekey failure (wrong passphrase, eval error) leaves the fleet
  # fully consistent on the old key instead of half-rotated with the
  # old private key destroyed.
  mkdir -p "$cache"
  chmod 0700 "$cache"
  local newkey="$cache/ssh_host_ed25519_key.new"
  rm -f "$newkey" "$newkey.pub"
  ssh-keygen -t ed25519 -N "" -C "nixhold-host-$name" -f "$newkey" >/dev/null
  nh_ok "generated new host keypair"

  mkdir -p "$keys_dir/hosts/$name"
  local oldpub_backup="" oldescrow_backup=""
  if [ -f "$keys_dir/hosts/$name/host.pub" ]; then
    oldpub_backup="$(mktemp -t nixhold-oldpub.XXXXXX)"
    cp "$keys_dir/hosts/$name/host.pub" "$oldpub_backup"
  fi
  if [ -f "$keys_dir/hosts/$name/host.key.age" ]; then
    oldescrow_backup="$(mktemp -t nixhold-oldescrow.XXXXXX)"
    cp "$keys_dir/hosts/$name/host.key.age" "$oldescrow_backup"
  fi

  # Escrow before the pubkey swap. An escrow ahead of its host.pub only
  # holds a key nothing uses yet; a host.pub ahead of its escrow is the
  # recovery dead end the escrow exists to prevent. Both are rolled
  # back together if the rekey below fails. A failure here aborts
  # before anything is swapped — rekey would fail on the same missing
  # operator key anyway.
  if ! nh_escrow_host_key "$name" "$newkey"; then
    rm -f "$newkey" "$newkey.pub" "$oldpub_backup" "$oldescrow_backup"
    nh_err "could not escrow the new host key — rotation aborted (nothing changed)"
    return 1
  fi

  cp "$newkey.pub" "$keys_dir/hosts/$name/host.pub"
  # A previously-uncommitted host.pub is untracked, and untracked
  # files are invisible to dirty git-flake eval — the recipients
  # computation would silently omit it.
  if git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$root" add --intent-to-add "$keys_dir/hosts/$name/host.pub" 2>/dev/null || true
  fi
  nh_ok "updated $keys_dir/hosts/$name/host.pub"

  # Re-encrypt to the rotated recipient set; the recipients option
  # reads the just-updated host.pub on the next eval.
  nh_info "re-encrypting secrets to the rotated recipient set"
  . "$NIXHOLD_LIB_ROOT/secret-rekey.sh"
  if ! cmd_secret_rekey; then
    if [ -n "$oldpub_backup" ]; then
      cp "$oldpub_backup" "$keys_dir/hosts/$name/host.pub"
      rm -f "$oldpub_backup"
    else
      rm -f "$keys_dir/hosts/$name/host.pub"
      nh_unstage_intent "$root" "$keys_dir/hosts/$name/host.pub"
    fi
    if [ -n "$oldescrow_backup" ]; then
      cp "$oldescrow_backup" "$keys_dir/hosts/$name/host.key.age"
      rm -f "$oldescrow_backup"
    else
      rm -f "$keys_dir/hosts/$name/host.key.age"
      nh_unstage_intent "$root" "$keys_dir/hosts/$name/host.key.age"
    fi
    # The replacement private key never reached the cache: the old
    # cached key is still the host's key, so "nothing changed" is
    # literally true.
    rm -f "$newkey" "$newkey.pub"
    nh_err "rekey failed — rotation rolled back (old key, recipients and ciphertexts unchanged)"
    return 1
  fi
  rm -f "$oldpub_backup" "$oldescrow_backup"

  # Swap the cache to the new key, keeping the old one for recovery.
  if [ -f "$cache/ssh_host_ed25519_key" ]; then
    mv "$cache/ssh_host_ed25519_key" "$cache/ssh_host_ed25519_key.old"
    if [ -f "$cache/ssh_host_ed25519_key.pub" ]; then
      mv "$cache/ssh_host_ed25519_key.pub" "$cache/ssh_host_ed25519_key.old.pub"
    fi
  fi
  mv "$newkey" "$cache/ssh_host_ed25519_key"
  mv "$newkey.pub" "$cache/ssh_host_ed25519_key.pub"
  nh_ok "cached new key at $cache (old key kept as ssh_host_ed25519_key.old)"

  nh_ok "rotate-key complete for $name"
  nh_info "commit keys/ + secrets/, then 'nixhold host install $name --remote …' (or 'nixhold deploy $name') to ship the new key"
}
