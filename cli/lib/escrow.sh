# Host-key escrow + repo deploy key (principle 16).
#
# Two ciphertexts live outside the per-host secrets tree because they
# exist to BOOTSTRAP it: `keys/hosts/<host>/host.key.age` (the host SSH
# private key) and `keys/repo.key.age` (the fleet repo's deploy key).
# Both are encrypted to the operator recipient ONLY — the host cannot
# decrypt its own escrow, and the ISO carries no key beyond the wrapped
# operator identity. Trust delta ≈ none: the operator recipient already
# decrypts every secret, so repo + passphrase was already total
# compromise.

# nh_operator_recipient_file -> path to the operator's age recipient
# (public) pubkey file in the working tree. Escrow encryption needs the
# recipient only, so every writer here stays non-interactive.
#
# `nh_worktree_layout_file` fails only when layout can't be probed —
# i.e. the fleet has no evaluable host yet, which is exactly the `host
# add <first>` case — so fall back to mkFleet's default location under
# keysDir (itself fallback-aware).
nh_operator_recipient_file() {
  local f
  f="$(nh_worktree_layout_file ageRecipient 2>/dev/null)" ||
    f="$(nh_worktree_keys_dir)/operator.pub" || return 2
  if [ ! -f "$f" ]; then
    nh_err "no operator recipient at $f — run 'nixhold init' and commit the pubkey it prints"
    return 1
  fi
  printf '%s' "$f"
}

# nh_escrow_host_key <host> <privkey-path> — encrypt the host SSH
# private key to the operator recipient and commit it as
# keys/hosts/<host>/host.key.age. Overwrites any existing escrow (the
# rotate-key path): the escrow tracks the key that is current, and a
# superseded host key is worthless.
nh_escrow_host_key() {
  local host="$1" key="$2" rcpt keys_dir out root
  if [ ! -f "$key" ]; then
    nh_err "no host private key at $key — nothing to escrow for $host"
    return 1
  fi
  rcpt="$(nh_operator_recipient_file)" || return 1
  keys_dir="$(nh_worktree_keys_dir)" || return 2
  out="$keys_dir/hosts/$host/host.key.age"
  mkdir -p "$keys_dir/hosts/$host"

  # Encrypt to a sibling temp + rename so an age failure can't leave a
  # truncated escrow standing next to a live host.pub.
  if ! age -R "$rcpt" -o "$out.tmp" "$key"; then
    rm -f "$out.tmp"
    nh_err "escrow encryption failed for $host (recipient $rcpt)"
    return 1
  fi
  if ! mv "$out.tmp" "$out"; then
    rm -f "$out.tmp"
    nh_err "could not write the escrow at $out"
    return 1
  fi
  chmod 0644 "$out"
  nh_ok "escrowed host key to $out"

  root="$(nh_fleet_root)" || return 0
  if git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$root" add --intent-to-add "$out" 2>/dev/null ||
      nh_warn "git add of $out failed — 'git add' it before committing"
  fi
}

# nh_resolve_host_key <host> <dest-dir> — materialize
# <dest-dir>/ssh_host_ed25519_key{,.pub} (0600/0644) for install /
# re-image. Cache first (no prompt), else the committed escrow
# (passphrase prompt), else fail. Nothing is generated: a host whose
# key is unrecoverable needs `host rotate-key`, which rekeys its
# secrets to the new key — silently minting one here would orphan
# every ciphertext the host owns.
#
# Backfilling a missing escrow from a cache hit is the caller's job
# (`nh_escrow_host_key`); this helper never writes into the fleet.
nh_resolve_host_key() {
  local host="$1" dest="$2" cache keys_dir esc
  cache="$NIXHOLD_CACHE_DIR/host-keys/$host"
  mkdir -p "$dest"

  if [ -f "$cache/ssh_host_ed25519_key" ]; then
    install -m 0600 "$cache/ssh_host_ed25519_key" "$dest/ssh_host_ed25519_key"
    if [ -f "$cache/ssh_host_ed25519_key.pub" ]; then
      install -m 0644 "$cache/ssh_host_ed25519_key.pub" "$dest/ssh_host_ed25519_key.pub"
    else
      nh_derive_host_pub "$dest/ssh_host_ed25519_key" || return 1
    fi
    nh_info "host key for $host from the local cache ($cache)"
    return 0
  fi

  keys_dir="$(nh_worktree_keys_dir)" || return 2
  esc="$keys_dir/hosts/$host/host.key.age"
  if [ ! -f "$esc" ]; then
    nh_err "no cached key and no escrow for $host — run 'nixhold host rotate-key $host'"
    return 1
  fi

  # Subshell + trap: the unwrapped operator identity never outlives the
  # decrypt, even on failure. errexit is ignored inside — the subshell
  # is an `if` condition — so each step is checked explicitly.
  if ! (
    set -euo pipefail
    idfile="$(mktemp -t nixhold-id.XXXXXX)" || exit 1
    chmod 600 "$idfile"
    trap 'rm -f "$idfile"' EXIT
    nh_unwrap_identity "$idfile" || exit 1
    age -d -i "$idfile" -o "$dest/ssh_host_ed25519_key" "$esc" || exit 1
  ); then
    rm -f "$dest/ssh_host_ed25519_key"
    nh_err "could not decrypt $esc (wrong passphrase, or the escrow predates the current operator key)"
    return 1
  fi
  chmod 0600 "$dest/ssh_host_ed25519_key"
  nh_derive_host_pub "$dest/ssh_host_ed25519_key" || return 1
  nh_info "host key for $host recovered from escrow"

  # Refresh the cache so later phases (and later runs) skip the
  # passphrase prompt.
  mkdir -p "$cache"
  chmod 0700 "$cache"
  install -m 0600 "$dest/ssh_host_ed25519_key" "$cache/ssh_host_ed25519_key"
  install -m 0644 "$dest/ssh_host_ed25519_key.pub" "$cache/ssh_host_ed25519_key.pub"
}

# nh_derive_host_pub <privkey-path> — write <privkey-path>.pub from the
# private key. The escrow holds the private half only; agenix and
# sshd both want the pubkey beside it.
nh_derive_host_pub() {
  local key="$1"
  if ! ssh-keygen -y -f "$key" >"$key.pub.tmp" 2>/dev/null; then
    rm -f "$key.pub.tmp"
    nh_err "$key is not a valid SSH private key — cannot derive its pubkey"
    return 1
  fi
  mv "$key.pub.tmp" "$key.pub"
  chmod 0644 "$key.pub"
}

# nh_ensure_repo_deploy_key — idempotent: generate + escrow
# keys/repo.key.age when missing, and print its pubkey for
# registration. The ISO carries this ciphertext so a bare installer can
# clone (and, for a new host, push) a private fleet repo with nothing
# but the operator passphrase — hence write access.
nh_ensure_repo_deploy_key() {
  local keys_dir out rcpt repo pub
  keys_dir="$(nh_worktree_keys_dir)" || return 2
  out="$keys_dir/repo.key.age"
  if [ -f "$out" ]; then
    return 0
  fi
  rcpt="$(nh_operator_recipient_file)" || return 1
  nh_require_cmd age ssh-keygen || return 1

  # Generate inside a private dir the trap wipes: the deploy key's
  # plaintext exists only between ssh-keygen and age. The ciphertext is
  # copied out before the trap fires; the pubkey is the subshell's only
  # stdout. errexit is ignored inside — the caller tests our exit code
  # — so every step exits explicitly; otherwise a failed cp would still
  # report a key that was never written.
  pub="$(
    (
      set -euo pipefail
      d="$(mktemp -d -t nixhold-repokey.XXXXXX)" || exit 1
      chmod 700 "$d"
      trap 'rm -rf "$d"' EXIT
      ssh-keygen -t ed25519 -N "" -C "nixhold-repo-deploy" -f "$d/key" >/dev/null || exit 1
      age -R "$rcpt" -o "$d/key.age" "$d/key" || exit 1
      mkdir -p "$keys_dir" || exit 1
      cp "$d/key.age" "$out" || exit 1
      chmod 0644 "$out" || exit 1
      cat "$d/key.pub"
    )
  )" || {
    rm -f "$out"
    nh_err "repo deploy key generation failed"
    return 1
  }

  nh_ok "generated repo deploy key, escrowed to the operator at $out"
  repo="$(nh_layout repoUrl 2>/dev/null | jq -r '. // empty')" || repo=""
  if [ -n "$repo" ]; then
    nh_info "register this pubkey as a deploy key on $repo WITH WRITE ACCESS (github.com/$repo/settings/keys → 'Add deploy key', tick 'Allow write access')"
  else
    nh_info "register this pubkey as a deploy key on your fleet repo WITH WRITE ACCESS (set layout.repoUrl so the CLI can name the repo)"
  fi
  echo "$pub"

  local root
  root="$(nh_fleet_root)" || return 0
  if git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$root" add --intent-to-add "$out" 2>/dev/null ||
      nh_warn "git add of $out failed — 'git add' it before committing"
  fi
}
