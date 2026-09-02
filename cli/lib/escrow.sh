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

# nh_escrow_host_key <host> <privkey-path> — commit BOTH halves of the
# host key from one private key: keys/hosts/<host>/host.key.age (the
# private half, encrypted to the operator recipient) and host.pub (the
# public half, the host's age recipient). One writer for the pair is
# what makes them provably the same key — nothing downstream, lint
# included, can tell an X25519 stanza's key from a pubkey file.
# Overwrites any existing escrow (the rotate-key path): the escrow
# tracks the key that is current, and a superseded host key is
# worthless. host.pub is left alone when it already holds this key, so
# a comment the operator committed survives.
nh_escrow_host_key() {
  local host="$1" key="$2" rcpt keys_dir out pub root
  if [ ! -f "$key" ]; then
    nh_err "no host private key at $key — nothing to escrow for $host"
    return 1
  fi
  rcpt="$(nh_operator_recipient_file)" || return 1
  keys_dir="$(nh_worktree_keys_dir)" || return 2
  out="$keys_dir/hosts/$host/host.key.age"
  pub="$keys_dir/hosts/$host/host.pub"
  if ! mkdir -p "$keys_dir/hosts/$host"; then
    nh_err "could not create $keys_dir/hosts/$host"
    return 1
  fi

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

  if ! nh_key_matches_pub "$key" "$pub"; then
    # Prefer the pubkey file beside the private key when it is really
    # its pair: it carries the comment ssh-keygen -y drops.
    if nh_key_matches_pub "$key" "$key.pub"; then
      cp "$key.pub" "$pub.tmp" || {
        rm -f "$pub.tmp"
        nh_err "could not stage the host recipient at $pub"
        return 1
      }
    elif ! ssh-keygen -y -f "$key" >"$pub.tmp" 2>/dev/null; then
      rm -f "$pub.tmp"
      nh_err "$key is not a valid SSH private key — $pub NOT written"
      return 1
    fi
    if ! mv "$pub.tmp" "$pub"; then
      rm -f "$pub.tmp"
      nh_err "could not write the host recipient at $pub"
      return 1
    fi
    chmod 0644 "$pub"
    nh_ok "committed the host recipient to $pub"
  fi

  root="$(nh_fleet_root)" || return 0
  if git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    # --intent-to-add: untracked files are invisible to dirty-flake
    # eval, so the recipients computation would silently omit host.pub.
    git -C "$root" add --intent-to-add "$out" "$pub" 2>/dev/null ||
      nh_warn "git add of $out / $pub failed — 'git add' them before committing"
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
  local host="$1" dest="$2" cache keys_dir esc committed
  cache="$NIXHOLD_CACHE_DIR/host-keys/$host"
  mkdir -p "$dest" || {
    nh_err "could not create the staging directory $dest"
    return 1
  }
  committed="$(nh_committed_host_pub "$host")" || return 2

  # A cache hit is only authoritative while it still derives the
  # committed recipient. A cached key from before someone else's
  # rotation looks identical on disk and silently backfills a WRONG
  # escrow (and installs a machine no secret decrypts on), so compare
  # first and fall through to the escrow — which is what the repo says
  # the host key is — when they disagree.
  if [ -f "$cache/ssh_host_ed25519_key" ]; then
    if [ -f "$committed" ] && ! nh_key_matches_pub "$cache/ssh_host_ed25519_key" "$committed"; then
      nh_warn "the cached key for $host is not the one committed as $committed — ignoring the cache and recovering from the escrow"
      nh_cache_supersede "$host" || return 1
    else
      if ! install -m 0600 "$cache/ssh_host_ed25519_key" "$dest/ssh_host_ed25519_key"; then
        nh_err "could not stage the cached host key for $host into $dest"
        return 1
      fi
      if [ -f "$cache/ssh_host_ed25519_key.pub" ]; then
        if ! install -m 0644 "$cache/ssh_host_ed25519_key.pub" "$dest/ssh_host_ed25519_key.pub"; then
          nh_err "could not stage the cached host pubkey for $host into $dest"
          return 1
        fi
      else
        nh_derive_host_pub "$dest/ssh_host_ed25519_key" || return 1
      fi
      nh_info "host key for $host from the local cache ($cache)"
      return 0
    fi
  fi

  keys_dir="$(nh_worktree_keys_dir)" || return 2
  esc="$keys_dir/hosts/$host/host.key.age"
  if [ ! -f "$esc" ]; then
    nh_err "no cached key and no escrow for $host — run 'nixhold host rotate-key $host'"
    return 1
  fi

  # Subshell: the unwrapped operator identity is staged in the process
  # scratch root, which the dispatcher's EXIT/INT/TERM/HUP handler wipes
  # — a trap installed HERE would not, since bash resets trapped signals
  # inside a subshell and Ctrl-C would leave the identity behind.
  # errexit is ignored inside (the subshell is an `if` condition), so
  # each step is checked explicitly.
  if ! (
    set -euo pipefail
    iddir="$(nh_tmpdir id)" || exit 1
    idfile="$(mktemp "$iddir/id.XXXXXX")" || exit 1
    chmod 600 "$idfile"
    nh_unwrap_identity "$idfile" || exit 1
    age -d -i "$idfile" -o "$dest/ssh_host_ed25519_key" "$esc" || exit 1
  ); then
    rm -f "$dest/ssh_host_ed25519_key"
    nh_err "could not decrypt $esc (wrong passphrase, or the escrow predates the current operator key)"
    return 1
  fi
  chmod 0600 "$dest/ssh_host_ed25519_key" || return 1
  nh_derive_host_pub "$dest/ssh_host_ed25519_key" || return 1
  if [ -f "$committed" ] && ! nh_key_matches_pub "$dest/ssh_host_ed25519_key" "$committed"; then
    nh_err "the escrow $esc holds a key that is NOT $committed — the fleet's recipient and its escrow disagree; 'nixhold host escrow $host' re-escrows the live key, 'nixhold host rotate-key $host' replaces both"
    rm -f "$dest/ssh_host_ed25519_key" "$dest/ssh_host_ed25519_key.pub"
    return 1
  fi
  nh_info "host key for $host recovered from escrow"

  # Refresh the cache so later phases (and later runs) skip the
  # passphrase prompt.
  nh_cache_host_key "$host" "$dest/ssh_host_ed25519_key"
}

# nh_pub_norm — an SSH pubkey line on stdin, "<type> <base64>" out
# (dropping the comment, which differs between copies of one key).
# Non-zero when the input is not a pubkey line at all, so a missing or
# truncated file can never compare equal to anything.
nh_pub_norm() {
  awk 'NF >= 2 { print $1 " " $2; found = 1; exit } END { exit(found ? 0 : 1) }'
}

# nh_key_matches_pub <privkey> <pubkey-file> — true when <privkey> is
# the private half of <pubkey-file>. The one place "is this the same
# key?" is decided.
nh_key_matches_pub() {
  local key="$1" pubfile="$2" derived committed
  [ -f "$key" ] && [ -f "$pubfile" ] || return 1
  derived="$(ssh-keygen -y -f "$key" 2>/dev/null | nh_pub_norm)" || return 1
  committed="$(nh_pub_norm <"$pubfile")" || return 1
  [ -n "$derived" ] && [ "$derived" = "$committed" ]
}

# nh_committed_host_pub <host> — path (existing or not) of the host's
# committed age/SSH recipient. Non-zero only when layout can't be
# probed.
nh_committed_host_pub() {
  local keys_dir
  keys_dir="$(nh_worktree_keys_dir)" || return 2
  printf '%s/hosts/%s/host.pub' "$keys_dir" "$1"
}

# nh_host_key_known <host> — true when a private key for <host> exists
# somewhere the CLI can reach it (cache or escrow), or a recipient is
# already committed for it. False means "this host has never had a
# key", which is the only case in which minting one is correct.
nh_host_key_known() {
  local host="$1" keys_dir committed
  [ -f "$NIXHOLD_CACHE_DIR/host-keys/$host/ssh_host_ed25519_key" ] && return 0
  keys_dir="$(nh_worktree_keys_dir)" || return 1
  [ -f "$keys_dir/hosts/$host/host.key.age" ] && return 0
  committed="$keys_dir/hosts/$host/host.pub"
  [ -f "$committed" ]
}

# nh_have_committed_host_key <host> — true when the fleet can produce
# the PRIVATE half of the committed host.pub (escrow, or a cache entry
# that still derives it). The question every "who is authoritative,
# machine or repo?" branch asks.
nh_have_committed_host_key() {
  local host="$1" keys_dir committed cached
  keys_dir="$(nh_worktree_keys_dir)" || return 1
  committed="$keys_dir/hosts/$host/host.pub"
  [ -f "$committed" ] || return 1
  [ -f "$keys_dir/hosts/$host/host.key.age" ] && return 0
  cached="$NIXHOLD_CACHE_DIR/host-keys/$host/ssh_host_ed25519_key"
  nh_key_matches_pub "$cached" "$committed"
}

# nh_cache_host_key <host> <privkey> — (re)populate the per-host key
# cache from a private key in hand. Single writer for the cache layout.
nh_cache_host_key() {
  local host="$1" key="$2" cache="$NIXHOLD_CACHE_DIR/host-keys/$1"
  if ! mkdir -p "$cache" || ! chmod 0700 "$cache"; then
    nh_err "could not create the host-key cache at $cache"
    return 1
  fi
  if ! install -m 0600 "$key" "$cache/ssh_host_ed25519_key"; then
    nh_err "could not cache the host key for $host at $cache"
    return 1
  fi
  if [ -f "$key.pub" ]; then
    install -m 0644 "$key.pub" "$cache/ssh_host_ed25519_key.pub" || {
      nh_err "could not cache the host pubkey for $host at $cache"
      return 1
    }
  else
    nh_derive_host_pub "$cache/ssh_host_ed25519_key" || return 1
  fi
}

# nh_cache_supersede <host> — move a cached key that is no longer the
# host's aside instead of deleting it. It is still the only copy of
# whatever that key was, and a wrong key in the way of a rotation is
# not a reason to destroy key material.
nh_cache_supersede() {
  local cache="$NIXHOLD_CACHE_DIR/host-keys/$1" f
  for f in ssh_host_ed25519_key ssh_host_ed25519_key.pub; do
    if [ -f "$cache/$f" ] && ! mv -f "$cache/$f" "$cache/$f.superseded"; then
      nh_err "could not move the stale cached key aside at $cache/$f"
      return 1
    fi
  done
  nh_info "kept the stale cached key as $cache/ssh_host_ed25519_key.superseded"
}

# nh_key_target <name> [remote] — where the verbs that touch a host's
# LIVE key (`host escrow`, `host install-key`, and `host rotate-key`'s
# install step) should act: prints an ssh target, or nothing at all for
# "this machine". Non-zero when neither applies; the caller says what
# that means for it — a hard error for a direct verb, a "not installed
# yet" notice mid-rotation.
#
# A darwin host is allowed to disagree about its own hostname: the
# macOS/MDM name and the fleet name routinely differ, exactly as
# `deploy` allows.
nh_key_target() {
  local name="$1" remote="${2:-}" here
  if [ -n "$remote" ]; then
    printf '%s' "$remote"
    return 0
  fi
  here="$(hostname -s 2>/dev/null || hostname)" || here=""
  [ "$here" = "$name" ] && return 0
  if [ "$(uname -s)" = "Darwin" ] &&
    [ "$(nh_host_platform "$name" 2>/dev/null || true)" = "darwin" ]; then
    nh_warn "local hostname is '$here', not '$name' — assuming this machine IS $name"
    return 0
  fi
  return 1
}

# nh_read_live_host_key <dest> [target] [host] — copy the machine's
# live /etc/ssh/ssh_host_ed25519_key into <dest> (0600): locally through
# sudo, or over ssh when <target> is given. Remote reads use `sudo -n`:
# the key travels on the connection's stdout, so there is no channel
# left for a password prompt — connect as root or as a passwordless-
# sudo user.
#
# <host> is the fleet host <target> is expected to be: a PRIVATE key
# comes back over that connection, so it is pinned to the key the fleet
# has committed for <host> whenever there is one (see lib/ssh.sh).
nh_read_live_host_key() {
  local dest="$1" target="${2:-}" host="${3:-}" src="/etc/ssh/ssh_host_ed25519_key"
  # shellcheck disable=SC2016 # runs on the TARGET's shell, not ours
  local remote_read='if [ "$(id -u)" -eq 0 ]; then cat /etc/ssh/ssh_host_ed25519_key; else sudo -n cat /etc/ssh/ssh_host_ed25519_key; fi'
  if ! (umask 077 && : >"$dest"); then
    nh_err "could not create $dest"
    return 1
  fi
  if [ -z "$target" ]; then
    if ! nh_sudo cat "$src" >"$dest"; then
      nh_err "could not read $src (sudo) — is this machine the host?"
      rm -f "$dest"
      return 1
    fi
  else
    if ! nh_ssh "$target" --host "$host" -- "$remote_read" >"$dest"; then
      nh_err "could not read $src on $target — connect as root, or as a user with passwordless sudo"
      rm -f "$dest"
      return 1
    fi
  fi
  if [ ! -s "$dest" ]; then
    nh_err "$src is empty${target:+ on $target} — nothing to escrow"
    rm -f "$dest"
    return 1
  fi
  nh_derive_host_pub "$dest" || {
    rm -f "$dest"
    return 1
  }
}

# nh_install_host_key <privkey> [target] [host] — make <privkey> the
# machine's /etc/ssh/ssh_host_ed25519_key: the single "ship the key to
# the box" path, used by `host install` (darwin, in place) and `host
# rotate-key` (local or over ssh). Derives the pubkey beside it and
# restarts sshd so the running daemon stops serving the superseded
# identity.
#
# <host> is the fleet host <target> is expected to be; the key travels
# TO the machine on that connection, so it is pinned exactly as the
# read path is (see lib/ssh.sh — mid-rotation the pin is the key the
# machine still runs, not the one just committed).
nh_install_host_key() {
  local key="$1" target="${2:-}" host="${3:-}"
  if [ ! -s "$key" ]; then
    nh_err "no host private key at $key — nothing to install"
    return 1
  fi
  if [ -z "$target" ]; then
    nh_install_host_key_local "$key"
  else
    nh_install_host_key_remote "$key" "$target" "$host"
  fi
}

nh_install_host_key_local() {
  local key="$1" dest="/etc/ssh/ssh_host_ed25519_key" d
  d="$(nh_tmpdir hostkey-install)" || return 1
  if ! ssh-keygen -y -f "$key" >"$d/pub" 2>/dev/null; then
    nh_err "$key is not a valid SSH private key — refusing to install it as $dest"
    return 1
  fi
  nh_info "installing the host key at $dest (sudo)"
  if ! nh_sudo install -d -m 0755 /etc/ssh; then
    nh_err "could not create /etc/ssh"
    return 1
  fi
  if ! nh_sudo install -m 0600 "$key" "$dest"; then
    nh_err "could not install the host key at $dest"
    return 1
  fi
  if ! nh_sudo install -m 0644 "$d/pub" "$dest.pub"; then
    nh_err "could not install $dest.pub"
    return 1
  fi
  nh_ok "installed the host key at $dest"
  nh_restart_sshd_local
}

nh_install_host_key_remote() {
  local key="$1" target="$2" host="${3:-}" hostpart="${2##*@}"
  # One snippet, run by the target's shell: the private key arrives on
  # stdin and never touches an argv or a shared /tmp path we chose. The
  # trap is the target's own cleanup — `set -e` means any failing step
  # below would otherwise leave the private key sitting in its /tmp.
  # shellcheck disable=SC2016 # runs on the TARGET's shell, not ours
  local script='
set -eu
umask 077
if [ "$(id -u)" -eq 0 ]; then S=""; else S="sudo -n"; fi
t="$(mktemp)"
trap '"'"'rm -f "$t" "$t.pub"'"'"' EXIT
cat >"$t"
chmod 600 "$t"
ssh-keygen -y -f "$t" >"$t.pub"
$S install -d -m 0755 /etc/ssh
$S install -m 0600 "$t" /etc/ssh/ssh_host_ed25519_key
$S install -m 0644 "$t.pub" /etc/ssh/ssh_host_ed25519_key.pub
rm -f "$t" "$t.pub"
if command -v systemctl >/dev/null 2>&1; then $S systemctl try-restart sshd.service || true; fi
'
  nh_info "installing the host key on $target"
  if ! nh_ssh "$target" --host "$host" -- "$script" <"$key"; then
    nh_err "could not install the host key on $target — connect as root, or as a user with passwordless sudo"
    return 1
  fi
  nh_ok "installed the host key on $target"
  # The target now answers with a different host key. The CLI's own pin
  # is regenerated per connection from the committed host.pub — which is
  # this key — but the OPERATOR's ~/.ssh/known_hosts (the file
  # `ssh-keygen -R` edits, used by their plain `ssh` and by
  # nixos-rebuild) still records the superseded one, which fails closed
  # and looks like an attack.
  if command -v ssh-keygen >/dev/null 2>&1; then
    ssh-keygen -R "$hostpart" >/dev/null 2>&1 ||
      nh_warn "could not drop the old entry for $hostpart from ~/.ssh/known_hosts — 'ssh-keygen -R $hostpart' if ssh complains the host key changed"
  fi
}

# nh_restart_sshd_local — best effort: a machine whose sshd keeps the
# old key in memory is confusing but not broken, and the install itself
# already succeeded.
nh_restart_sshd_local() {
  case "$(uname -s)" in
    Darwin)
      if launchctl print system/com.openssh.sshd >/dev/null 2>&1; then
        nh_sudo launchctl kickstart -k system/com.openssh.sshd >/dev/null 2>&1 ||
          nh_warn "could not restart sshd — it serves the old host key until Remote Login is toggled or the machine reboots"
      fi
      ;;
    *)
      if command -v systemctl >/dev/null 2>&1; then
        nh_sudo systemctl try-restart sshd.service >/dev/null 2>&1 ||
          nh_warn "could not restart sshd — it serves the old host key until it is restarted"
      fi
      ;;
  esac
  return 0
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

  # Generate inside the process scratch root, which the dispatcher's
  # EXIT/INT/TERM/HUP handler wipes: the deploy key's plaintext exists
  # only between ssh-keygen and age, and a subshell-local trap would not
  # survive a Ctrl-C here. The ciphertext is copied out first; the
  # pubkey is the subshell's only stdout. errexit is ignored inside —
  # the caller tests our exit code — so every step exits explicitly;
  # otherwise a failed cp would still report a key that was never
  # written.
  pub="$(
    (
      set -euo pipefail
      d="$(nh_tmpdir repokey)" || exit 1
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
