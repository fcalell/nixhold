# nixhold host rotate-key <name>
#
# Generates a fresh SSH host keypair for <name>, commits the new
# pubkey under keysDir (so it becomes the host's age recipient), then
# re-encrypts every secret to the rotated recipient set. Used after a
# lost key cache (L10 recovery) or a routine key rotation; follow with
# `nixhold host install <name>` (to ship the new key) or `deploy`.

cmd_host_rotate_key() {
  local name="$1"
  if [ -z "$name" ]; then
    nh_err "expected: nixhold host rotate-key <name>"
    return 1
  fi
  nh_require_cmd ssh-keygen age jq nix

  nh_host_platform "$name" >/dev/null || {
    nh_err "host '$name' not found in fleet"
    return 1
  }

  local cache keys_dir
  cache="$NIXHOLD_CACHE_DIR/host-keys/$name"
  keys_dir="$(nh_worktree_keys_dir)"

  if [ -f "$cache/ssh_host_ed25519_key" ] &&
    ! nh_prompt_confirm "Replace the existing cached key for $name? (old ciphertext becomes undecryptable by the old host key)"; then
    nh_info "aborted"
    return 0
  fi

  mkdir -p "$cache"
  chmod 0700 "$cache"
  rm -f "$cache/ssh_host_ed25519_key" "$cache/ssh_host_ed25519_key.pub"
  ssh-keygen -t ed25519 -N "" -C "nixhold-host-$name" -f "$cache/ssh_host_ed25519_key" >/dev/null
  nh_ok "generated new host keypair at $cache"

  mkdir -p "$keys_dir/hosts/$name"
  cp "$cache/ssh_host_ed25519_key.pub" "$keys_dir/hosts/$name/host.pub"
  nh_ok "updated $keys_dir/hosts/$name/host.pub"

  # Re-encrypt to the rotated recipient set. The recipients option
  # reads the just-updated host.pub on the next eval (a tracked file
  # modified in place is visible to the dirty-tree flake eval), so the
  # new host key becomes a recipient of every secret.
  nh_info "re-encrypting secrets to the rotated recipient set"
  . "$NIXHOLD_LIB_ROOT/secret-rekey.sh"
  cmd_secret_rekey

  nh_ok "rotate-key complete for $name"
  nh_info "commit keys/ + secrets/, then 'nixhold host install $name --remote …' (or 'nixhold deploy $name') to ship the new key"
}
