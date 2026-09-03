# nixhold host rotate-key <name> [--remote <user>@<ip>] [--no-install]
#                                [--yes]
#
# Generates a fresh SSH host keypair for <name>, commits the new pubkey
# + escrow under keysDir (so it becomes the host's age recipient),
# re-encrypts every secret to the rotated recipient set, and then
# SHIPS the key: a rotation the machine never receives is not a
# rotation, it is an outage waiting for the next activation. The
# install step targets the machine the same way `host install` does —
# `--remote <user>@<ip>`, or in place when this machine is <name>.
#
# Used after a lost key cache (L10 recovery) or a routine rotation.
# Follow with `nixhold deploy <name>` so the host also receives the
# ciphertexts that were just re-encrypted to it.

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

# Rollback state. The window between "the new key is committed" and
# "the rekey succeeded" is the only inconsistent moment in the verb, so
# its undo is a handler the dispatcher's EXIT/INT/TERM trap runs —
# a Ctrl-C at the rekey passphrase prompt now rolls back exactly like a
# wrong passphrase does, instead of leaving new keys against old
# ciphertexts.
_NH_ROTATE_ACTIVE=0
_NH_ROTATE_NAME=""
_NH_ROTATE_ROOT=""
_NH_ROTATE_DIR=""
_NH_ROTATE_CACHE=""
_NH_ROTATE_OLDPUB=""
_NH_ROTATE_OLDESCROW=""
_NH_ROTATE_NEWKEY=""

nh_rotate_rollback() {
  [ "$_NH_ROTATE_ACTIVE" -eq 1 ] || return 0
  _NH_ROTATE_ACTIVE=0
  local dir="$_NH_ROTATE_DIR"

  # No rotation happened, so nothing is superseded: drop the "the
  # machine still runs the previous key" record before it can widen a
  # later connection's pin set (lib/ssh.sh).
  if [ -n "$_NH_ROTATE_CACHE" ]; then
    rm -f "$_NH_ROTATE_CACHE/host.pub.prev"
  fi

  if [ -n "$_NH_ROTATE_OLDPUB" ] && [ -f "$_NH_ROTATE_OLDPUB" ]; then
    cp "$_NH_ROTATE_OLDPUB" "$dir/host.pub" ||
      nh_err "could not restore $dir/host.pub from $_NH_ROTATE_OLDPUB — restore it by hand before deploying"
  else
    rm -f "$dir/host.pub"
    nh_unstage_intent "$_NH_ROTATE_ROOT" "$dir/host.pub"
  fi

  if [ -n "$_NH_ROTATE_OLDESCROW" ] && [ -f "$_NH_ROTATE_OLDESCROW" ]; then
    cp "$_NH_ROTATE_OLDESCROW" "$dir/host.key.age" ||
      nh_err "could not restore $dir/host.key.age from $_NH_ROTATE_OLDESCROW — restore it by hand"
  else
    rm -f "$dir/host.key.age"
    nh_unstage_intent "$_NH_ROTATE_ROOT" "$dir/host.key.age"
  fi

  # The replacement private key never reached the cache under its real
  # name: the old cached key is still the host's key, so "nothing
  # changed" is literally true.
  rm -f "$_NH_ROTATE_NEWKEY" "$_NH_ROTATE_NEWKEY.pub"
  nh_err "rotation rolled back for $_NH_ROTATE_NAME (old key, recipients and ciphertexts unchanged)"
}

cmd_host_rotate_key() {
  local name="" remote="" no_install=0 yes=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --remote) remote="${2:-}"; shift 2 ;;
      --no-install) no_install=1; shift ;;
      --yes) yes=1; shift ;;
      -h | --help)
        cat <<'EOF'
Usage: nixhold host rotate-key <name> [--remote <user>@<ip>]
                                      [--no-install] [--yes]

  --remote      ship the new key to the running machine over SSH
                (connect as root, or as a passwordless-sudo user).
                Without it the key is installed in place when this
                machine is <name>.
  --no-install  rotate the repo side only; the machine keeps the old
                key until you install it.
EOF
        return 0
        ;;
      -*) nh_err "unknown flag: $1"; return 1 ;;
      *) if [ -z "$name" ]; then name="$1"; shift; else nh_err "extra arg: $1"; return 1; fi ;;
    esac
  done
  if [ -z "$name" ]; then
    nh_err "expected: nixhold host rotate-key <name>"
    return 1
  fi
  if [ -n "$remote" ] && [ "$no_install" -eq 1 ]; then
    nh_err "--remote and --no-install contradict each other"
    return 1
  fi
  nh_require_cmd ssh-keygen age jq nix || return 1

  nh_host_platform "$name" >/dev/null || {
    nh_err "host '$name' is not in this fleet — 'nixhold status --fleet' lists the roster"
    return 1
  }

  local root cache keys_dir dir
  root="$(nh_fleet_root)" || return 1
  cache="$NIXHOLD_CACHE_DIR/host-keys/$name"
  keys_dir="$(nh_worktree_keys_dir)" || return 2
  dir="$keys_dir/hosts/$name"

  if [ -f "$cache/ssh_host_ed25519_key" ] &&
    ! nh_prompt_confirm "Replace the existing cached key for $name? (old ciphertext becomes undecryptable by the old host key)"; then
    nh_info "aborted"
    return 0
  fi

  # Generate the replacement under a temp name. The old key and the
  # committed pubkey are swapped only AFTER the rekey succeeds, so a
  # mid-rekey failure (wrong passphrase, eval error, Ctrl-C) leaves the
  # fleet fully consistent on the old key instead of half-rotated with
  # the old private key destroyed.
  if ! mkdir -p "$cache" || ! chmod 0700 "$cache"; then
    nh_err "could not create the host-key cache at $cache"
    return 1
  fi
  local newkey="$cache/ssh_host_ed25519_key.new"
  rm -f "$newkey" "$newkey.pub"
  ssh-keygen -t ed25519 -N "" -C "nixhold-host-$name" -f "$newkey" >/dev/null || {
    nh_err "could not generate a replacement keypair at $newkey"
    return 1
  }
  nh_ok "generated new host keypair"

  if ! mkdir -p "$dir"; then
    nh_err "could not create $dir"
    return 1
  fi

  local backups
  backups="$(nh_tmpdir rotate)" || return 1
  local oldpub_backup="" oldescrow_backup=""
  if [ -f "$dir/host.pub" ]; then
    oldpub_backup="$backups/host.pub"
    cp "$dir/host.pub" "$oldpub_backup" || {
      nh_err "could not back up $dir/host.pub — rotation aborted (nothing changed)"
      return 1
    }
    # host.pub is about to name the NEW key while the machine goes on
    # answering with this one until the install step below succeeds.
    # Recorded beside the superseded escrow (same lifetime, same
    # meaning: "the key $name is still running"), it is what lets
    # nh_ssh PIN the connection that ships the replacement instead of
    # trusting it blind — the connection that carries the new private
    # key. Deleted the moment the machine has the new key.
    cp "$dir/host.pub" "$cache/host.pub.prev" || {
      nh_err "could not record the superseded pubkey at $cache/host.pub.prev — rotation aborted (nothing changed)"
      return 1
    }
  fi
  if [ -f "$dir/host.key.age" ]; then
    oldescrow_backup="$backups/host.key.age"
    cp "$dir/host.key.age" "$oldescrow_backup" || {
      nh_err "could not back up $dir/host.key.age — rotation aborted (nothing changed)"
      return 1
    }
    # The superseded escrow is the ONLY copy of the old private key
    # when this operator had no cache (the L10 recovery path), and the
    # live machine still runs that key until the install step below
    # succeeds. Keep it out of the repo but on disk until then.
    cp "$dir/host.key.age" "$cache/host.key.age.prev" || {
      nh_err "could not keep the previous escrow at $cache/host.key.age.prev — rotation aborted (nothing changed)"
      return 1
    }
    chmod 0600 "$cache/host.key.age.prev" 2>/dev/null || true
  fi

  _NH_ROTATE_NAME="$name"
  _NH_ROTATE_ROOT="$root"
  _NH_ROTATE_DIR="$dir"
  _NH_ROTATE_CACHE="$cache"
  _NH_ROTATE_OLDPUB="$oldpub_backup"
  _NH_ROTATE_OLDESCROW="$oldescrow_backup"
  _NH_ROTATE_NEWKEY="$newkey"
  nh_at_exit nh_rotate_rollback
  _NH_ROTATE_ACTIVE=1

  # One writer for host.pub + host.key.age, from the one private key
  # this rotation generated — they cannot end up describing different
  # keys. A failure here aborts before the rekey; rekey would fail on
  # the same missing operator key anyway.
  if ! nh_escrow_host_key "$name" "$newkey"; then
    nh_rotate_rollback
    nh_err "could not commit the new host key + escrow — rotation aborted"
    return 1
  fi

  # Re-encrypt to the rotated recipient set; the recipients option
  # reads the just-updated host.pub on the next eval.
  nh_info "re-encrypting secrets to the rotated recipient set"
  . "$NIXHOLD_LIB_ROOT/secret-rekey.sh"
  if ! cmd_secret_rekey; then
    nh_rotate_rollback
    nh_err "rekey failed — rotation rolled back"
    return 1
  fi
  _NH_ROTATE_ACTIVE=0

  # Swap the cache to the new key, keeping the old one for recovery.
  if [ -f "$cache/ssh_host_ed25519_key" ]; then
    mv -f "$cache/ssh_host_ed25519_key" "$cache/ssh_host_ed25519_key.old" || {
      nh_err "could not move the old cached key aside at $cache"
      return 1
    }
    if [ -f "$cache/ssh_host_ed25519_key.pub" ]; then
      mv -f "$cache/ssh_host_ed25519_key.pub" "$cache/ssh_host_ed25519_key.old.pub" ||
        nh_warn "could not move $cache/ssh_host_ed25519_key.pub aside"
    fi
  fi
  if ! mv -f "$newkey" "$cache/ssh_host_ed25519_key" ||
    ! mv -f "$newkey.pub" "$cache/ssh_host_ed25519_key.pub"; then
    nh_err "could not cache the new key at $cache — it is committed and escrowed; recover it with 'nixhold host install $name'"
    return 1
  fi
  nh_ok "cached new key at $cache (old key kept as ssh_host_ed25519_key.old)"
  nh_ok "rotate-key complete for $name"

  nh_rotate_install "$name" "$remote" "$no_install" "$yes"
}

# nh_rotate_install <name> <remote> <no-install> <yes> —
# the second half of a rotation: put the new key on the machine. Until
# it runs, the fleet's recipients and the machine disagree and the host
# decrypts nothing on its next activation — which is why this is part
# of the verb and not a line of advice at the end of it.
nh_rotate_install() {
  local name="$1" remote="$2" no_install="$3" yes="$4"
  local cache="$NIXHOLD_CACHE_DIR/host-keys/$name"
  local target=""

  if [ "$no_install" -eq 1 ]; then
    nh_rotate_pending "$name" "the machine still runs the old key (--no-install)"
    return 0
  fi

  # Same resolver the standalone verb uses; a machine we cannot reach
  # is a pending rotation, not an error.
  target="$(nh_key_target "$name" "$remote")" || {
    nh_rotate_pending "$name" "this machine is not $name and no --remote was given"
    return 0
  }

  if [ "$yes" -ne 1 ] &&
    ! nh_prompt_confirm "Install the new host key on ${target:-this machine} now? (it stops answering with the old one)"; then
    nh_rotate_pending "$name" "you declined the install"
    return 0
  fi

  # One implementation, shared with `nixhold host key`: resolve the
  # committed key (now the rotated one) and put it on the machine.
  if ! nh_install_committed_key "$name" "$target"; then
    nh_rotate_pending "$name" "the install failed"
    return 1
  fi

  # The machine now holds the rotated key, so the superseded escrow is
  # no longer anyone's only copy of a live key — and the superseded
  # pubkey is no longer a key any connection to $name should accept.
  rm -f "$cache/host.key.age.prev" "$cache/host.pub.prev"
  nh_ok "$name now runs the rotated key"
  nh_info "commit keys/ + secrets/, then 'nixhold deploy $name' so the host receives the re-encrypted ciphertexts"
}

# nh_rotate_pending <name> <reason> — one message for every path that
# leaves the key committed but not installed, naming where the previous
# private key still is.
nh_rotate_pending() {
  local name="$1" reason="$2"
  local cache="$NIXHOLD_CACHE_DIR/host-keys/$name"
  nh_warn "$name's new key is committed but NOT installed — $reason"
  # `host key` finishes exactly this rotation — the fleet holds the
  # committed key, so it goes onto the machine; no new key, no
  # reformat (which is why `host install` is NOT the advice here).
  nh_info "finish it with: nixhold host key $name --remote <user>@<ip> (or run it on $name itself)"
  if [ -f "$cache/host.key.age.prev" ]; then
    nh_info "the previous escrow is kept at $cache/host.key.age.prev until the new key is installed — it is the key $name is still running"
  fi
  nh_info "commit keys/ + secrets/, then 'nixhold deploy $name' once the key is in place"
}
