# The operator seat and THE FLEET KEY.
#
# Two kinds of key material live outside the secrets tree because they
# are what opens it:
#
#   keys/operator.pub   the operator's age recipients, ONE PER LINE — a
#                       FIDO2 token line (age1fido2-hmac1…), the
#                       passphrase identity's plain age1… line, or both.
#   keys/operator.age   the passphrase-wrapped operator identity, on a
#                       fleet that has one at all (a token-only fleet
#                       commits none).
#   keys/fleet.key.age  THE fleet age identity, encrypted to the
#                       operator lines and to nothing else.
#   keys/fleet.pub      its recipient line, public.
#
# Every ciphertext under `secrets/` is encrypted to the operator lines
# plus keys/fleet.pub, and every host holds the same private half at
# /etc/nixhold/fleet.key (0400 root) with /etc/nixhold/fleet.pub (0444)
# beside it, so a verb can ask a machine WHICH key it holds with a
# plain `cat`. One recipient set for the fleet: no per-host sets, no
# sidecars, no widen, and `secret rekey` is needed only when the
# operator recipients change or the fleet key rotates.
#
# Host SSH keys are ordinary keys here: generated fresh at install,
# committed as keys/hosts/<host>.pub for known_hosts pinning only,
# never a recipient and never escrowed.

# nh_operator_recipient_file -> path to the operator's age recipients
# file in the working tree: ONE RECIPIENT PER LINE, handed to
# `age -R`. Encryption needs the recipients only — not the token,
# whose public half is inside its recipient line — so every writer
# here stays non-interactive.
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
    nh_ensure_operator_identity || return 1
  fi
  printf '%s' "$f"
}

# nh_ensure_operator_identity — the fleet's first need for the
# operator recipients (minting the fleet key) is where a passphrase
# identity gets made: generate an age keypair, wrap the private half
# with a passphrase, write the wrapped half under keysDir and APPEND
# its recipient to the recipients file.
#
# A fleet whose recipients file already holds a line — a token
# recipient the operator enrolled by hand, a passphrase recipient, or
# both — generates NOTHING: it already has a seat, and a second
# identity nobody asked for would be a key to lose. Generation is only
# the empty-file case. A wrapped identity with no recipient line is
# still refused rather than completed: the missing line is somewhere,
# and a new identity would orphan what the present half already guards.
nh_ensure_operator_identity() {
  local pub wrapped root tmpdir
  pub="$(nh_worktree_layout_file ageRecipient 2>/dev/null)" ||
    pub="$(nh_worktree_keys_dir)/operator.pub" || return 2
  wrapped="$(nh_worktree_layout_file ageIdentityWrapped 2>/dev/null)" ||
    wrapped="$(nh_worktree_keys_dir)/operator.age" || return 2
  if nh_pubkey_lines "$pub" >/dev/null; then
    return 0
  fi
  if [ -f "$wrapped" ]; then
    nh_err "$wrapped exists but $pub names no recipient — restore the recipient line from another checkout (age-keygen -y on the unwrapped identity prints it)"
    return 1
  fi
  if ! nh_tty; then
    nh_err "this fleet has no operator recipient ($pub is missing or empty) — run 'nixhold host add' on a terminal to generate a passphrase identity, or commit your FIDO2 token's age1fido2-hmac1… recipient there"
    return 1
  fi
  nh_require_cmd age age-keygen || return 1
  nh_info "this fleet has no operator recipient yet — the operator seat is what decrypts the fleet key and every secret (a FIDO2 token recipient can be committed to $pub instead; this generates the passphrase kind)"
  if ! nh_prompt_confirm "Generate it now? (you will choose its passphrase; losing that passphrase is unrecoverable)"; then
    nh_err "no operator identity — nothing was written"
    return 1
  fi
  # The unwrapped identity exists only between age-keygen and `age -p`,
  # under the scratch root the dispatcher wipes on every exit path.
  tmpdir="$(nh_tmpdir identity)" || return 1
  age-keygen -o "$tmpdir/identity" >/dev/null 2>&1 || {
    nh_err "age-keygen failed"
    return 1
  }
  mkdir -p "$(dirname "$wrapped")" "$(dirname "$pub")" || return 1
  nh_info "wrapping the identity with your passphrase (you'll be prompted twice)"
  if ! age -p -o "$wrapped" "$tmpdir/identity"; then
    rm -f "$wrapped"
    nh_err "could not wrap the operator identity — nothing was written"
    return 1
  fi
  # Appended, not written over: $pub is a recipients file, and an
  # operator who enrolls a token later adds a line to this same file.
  if ! age-keygen -y "$tmpdir/identity" >>"$pub"; then
    rm -f "$wrapped"
    nh_err "could not derive the operator recipient — nothing was written"
    return 1
  fi
  chmod 0644 "$wrapped" "$pub"
  nh_ok "operator identity written: a recipient line in $pub + $wrapped (wrapped private key)"
  root="$(nh_fleet_root)" || return 0
  nh_stage_for_eval "$root" "$pub" "$wrapped"
}

# ---------------------------------------------------------------------
# The fleet key.

# nh_fleet_key_file / nh_fleet_pub_file — the committed pair's paths
# (existing or not). Non-zero only when keysDir can't be resolved.
nh_fleet_key_file() {
  local keys_dir
  keys_dir="$(nh_worktree_keys_dir)" || return 2
  printf '%s/fleet.key.age' "$keys_dir"
}

nh_fleet_pub_file() {
  local keys_dir
  keys_dir="$(nh_worktree_keys_dir)" || return 2
  printf '%s/fleet.pub' "$keys_dir"
}

# nh_fleet_pub_line -> the fleet's age recipient line; non-zero when
# the fleet has no fleet.pub yet.
nh_fleet_pub_line() {
  local pub
  pub="$(nh_fleet_pub_file)" || return 2
  nh_pubkey_line "$pub"
}

# nh_fleet_key_ensure — idempotent: mint the fleet key when the fleet
# has none. Half a pair is refused rather than completed — a fleet.pub
# without its ciphertext names a key nobody holds, and a fleet.key.age
# without its pubkey would be re-minted into a key no host has, which
# is a `secret rotate`, not a repair.
nh_fleet_key_ensure() {
  local key pub
  key="$(nh_fleet_key_file)" || return 2
  pub="$(nh_fleet_pub_file)" || return 2
  if [ -f "$key" ] && nh_pubkey_line "$pub" >/dev/null; then
    return 0
  fi
  if [ -f "$key" ]; then
    nh_err "$key exists but $pub holds no recipient line — restore it from another checkout, or 'nixhold secret rotate' to mint a new fleet key and re-encrypt everything to it"
    return 1
  fi
  if [ -e "$pub" ] && nh_pubkey_line "$pub" >/dev/null; then
    nh_err "$pub names a fleet key but $key is missing — restore it from another checkout; without it nothing can decrypt this fleet ('nixhold secret rotate' only helps while the operator can still open the secrets)"
    return 1
  fi
  nh_info "this fleet has no fleet key yet — minting the one age identity every host decrypts with"
  nh_fleet_key_mint
}

# nh_fleet_key_mint — generate a fleet age identity and write BOTH
# halves: keys/fleet.key.age (encrypted to the operator lines and
# nothing else) and keys/fleet.pub. Overwrites an existing pair, which
# is what `secret rotate` is: the caller re-encrypts every secret to
# the new recipient and deploys it to every host.
nh_fleet_key_mint() {
  local rcpt key pub tmpdir root
  rcpt="$(nh_operator_recipient_file)" || return 1
  nh_age_require_encrypt || return 1
  nh_require_cmd age age-keygen || return 1
  key="$(nh_fleet_key_file)" || return 2
  pub="$(nh_fleet_pub_file)" || return 2
  mkdir -p "$(dirname "$key")" || return 1

  # The plaintext identity exists only between age-keygen and age,
  # under the process scratch root the dispatcher wipes on every exit
  # path (EXIT/INT/TERM/HUP alike).
  tmpdir="$(nh_tmpdir fleet-key)" || return 1
  if ! age-keygen -o "$tmpdir/fleet.key" >/dev/null 2>&1; then
    nh_err "age-keygen failed — no fleet key was written"
    return 1
  fi
  if ! age-keygen -y "$tmpdir/fleet.key" >"$pub.tmp" 2>/dev/null; then
    rm -f "$pub.tmp"
    nh_err "could not derive the fleet recipient — nothing was written"
    return 1
  fi
  if ! age -R "$rcpt" -o "$key.tmp" "$tmpdir/fleet.key"; then
    rm -f "$key.tmp" "$pub.tmp"
    nh_err "could not encrypt the fleet key to the operator recipients in $rcpt"
    return 1
  fi
  if ! mv "$key.tmp" "$key" || ! mv "$pub.tmp" "$pub"; then
    rm -f "$key.tmp" "$pub.tmp"
    nh_err "could not write the fleet key pair under $(dirname "$key")"
    return 1
  fi
  chmod 0644 "$key" "$pub"
  # The process may already hold the PREVIOUS fleet key unwrapped (a
  # rotation is a mint on top of a live fleet); drop that memo so
  # everything downstream installs and re-wraps the key just written.
  rm -f "$(nh_tmp_root)/fleet-key"
  nh_ok "fleet key written: $pub (recipient) + $key (wrapped to the operator)"
  root="$(nh_fleet_root)" || return 0
  nh_stage_for_eval "$root" "$key" "$pub"
}

# nh_fleet_key_plain -> path of the UNWRAPPED fleet key, opening it
# (one passphrase prompt, or one token touch) the first time it is
# asked for in this CLI process. The plaintext lives in the process
# scratch root — $$-keyed, so subshells agree on it — which the
# dispatcher's EXIT/INT/TERM/HUP handler wipes. An install that stages
# it into /mnt and then hands it to another phase therefore costs one
# unlock, not three.
nh_fleet_key_plain() {
  local root out key
  root="$(nh_tmp_root)" || return 1
  out="$root/fleet-key"
  if [ -s "$out" ]; then
    printf '%s' "$out"
    return 0
  fi
  key="$(nh_fleet_key_file)" || return 2
  if [ ! -f "$key" ]; then
    nh_err "no fleet key at $key — 'nixhold secret rekey' mints one and re-encrypts every secret to it"
    return 1
  fi
  if ! (umask 077 && : >"$out"); then
    nh_err "could not create $out"
    return 1
  fi
  if ! nh_age_decrypt "$key" "$out"; then
    rm -f "$out"
    nh_err "$key was not opened by the operator's seat — plug in the token, or run from a checkout that holds keys/operator.age"
    return 1
  fi
  chmod 0600 "$out" || return 1
  printf '%s' "$out"
}

# nh_fleet_key_decrypt_to <out> — the fleet identity in plaintext at
# <out> (0600). <out> belongs under the process scratch root; it exists
# only on success.
nh_fleet_key_decrypt_to() {
  local out="$1" src
  src="$(nh_fleet_key_plain)" || return $?
  if ! install -m 0600 "$src" "$out"; then
    nh_err "could not stage the fleet key at $out"
    return 1
  fi
}

# nh_fleet_key_install [--remote <user>@<ip> [--host <name>]]
#                      [--root <dir>] [--stage <dir>]
#
# Put /etc/nixhold/fleet.key (0400 root) and /etc/nixhold/fleet.pub
# (0444) where a host will read them. Four targets, one writer:
#
#   (no flags)      this machine, through sudo
#   --remote        a running machine, through nh_ssh_sudo (--host
#                   names the fleet host so the connection is pinned)
#   --root <dir>    a mounted root the installer owns — /mnt during
#                   `host install`; sudo, since /mnt/etc is root's
#   --stage <dir>   a staging tree the CLI owns and something else
#                   copies as root (nixos-anywhere --extra-files); no
#                   sudo, and the modes are what the copy preserves
nh_fleet_key_install() {
  local remote="" host="" root="" stage="" d line
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --remote)
        remote="${2:-}"
        shift 2
        ;;
      --host)
        host="${2:-}"
        shift 2
        ;;
      --root)
        root="${2:-}"
        shift 2
        ;;
      --stage)
        stage="${2:-}"
        shift 2
        ;;
      *)
        nh_err "nh_fleet_key_install: unknown argument '$1'"
        return 1
        ;;
    esac
  done

  line="$(nh_fleet_pub_line)" || {
    nh_err "no fleet recipient at $(nh_fleet_pub_file 2>/dev/null) — nothing to install"
    return 1
  }
  d="$(nh_tmpdir fleet-key-install)" || return 1
  nh_fleet_key_decrypt_to "$d/fleet.key" || return 1
  printf '%s\n' "$line" >"$d/fleet.pub" || return 1
  chmod 0644 "$d/fleet.pub" || return 1

  if [ -n "$stage" ]; then
    if ! install -d -m 0755 "$stage/etc/nixhold" ||
      ! install -m 0400 "$d/fleet.key" "$stage/etc/nixhold/fleet.key" ||
      ! install -m 0444 "$d/fleet.pub" "$stage/etc/nixhold/fleet.pub"; then
      nh_err "could not stage the fleet key under $stage/etc/nixhold"
      return 1
    fi
    nh_ok "staged the fleet key into $stage/etc/nixhold"
    return 0
  fi

  if [ -n "$remote" ]; then
    nh_fleet_key_install_remote "$remote" "$host" "$d/fleet.key" "$line"
    return $?
  fi

  local dir="${root:+$root}/etc/nixhold"
  if ! nh_sudo install -d -m 0755 "$dir" ||
    ! nh_sudo install -m 0400 "$d/fleet.key" "$dir/fleet.key" ||
    ! nh_sudo install -m 0444 "$d/fleet.pub" "$dir/fleet.pub"; then
    nh_err "could not install the fleet key at $dir (sudo)"
    return 1
  fi
  nh_ok "installed the fleet key at $dir"
}

# nh_fleet_key_install_remote <target> <fleet-host> <keyfile> <publine>
# — one snippet run by the target's shell: the private key arrives on
# stdin and never touches an argv or a shared /tmp path we chose. The
# recipient line is public, so it travels in the snippet itself. The
# trap is the target's own cleanup — `set -e` means any failing step
# would otherwise leave the plaintext key in its /tmp.
nh_fleet_key_install_remote() {
  local target="$1" host="${2:-}" key="$3" line="$4" script
  # shellcheck disable=SC2016 # runs on the TARGET's shell, not ours
  # `nh_rsudo` comes from nh_ssh_sudo's preamble, which has already
  # consumed the password line off stdin — so the `cat` below reads the
  # fleet key and nothing else.
  script='
set -eu
umask 077
t="$(mktemp)"
trap '"'"'rm -f "$t" "$t.pub"'"'"' EXIT
cat >"$t"
printf '"'"'%s\n'"'"' '"$(printf '%q' "$line")"' >"$t.pub"
nh_rsudo install -d -m 0755 /etc/nixhold
nh_rsudo install -m 0400 "$t" /etc/nixhold/fleet.key
nh_rsudo install -m 0444 "$t.pub" /etc/nixhold/fleet.pub
rm -f "$t" "$t.pub"
'
  local hostargs=()
  [ -n "$host" ] && hostargs=(--host "$host")
  nh_info "installing the fleet key on $target"
  if ! nh_ssh_sudo "$target" "${hostargs[@]}" -- "$script" <"$key"; then
    nh_err "could not install the fleet key on $target — connect as root, or as the operator (its sudo password is what the prompt asks for)"
    return 1
  fi
  nh_ok "installed the fleet key on $target"
}

# nh_fleet_key_read_pub [--remote <user>@<ip>] [--host <name>] — the
# recipient line the MACHINE holds at /etc/nixhold/fleet.pub, or
# nothing at all when it holds none. 0444, so no escalation is needed
# to read it — but the remote read goes through nh_ssh_sudo anyway,
# since the caller that finds a mismatch installs over the same
# connection.
nh_fleet_key_read_pub() {
  local remote="" host="" out
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --remote)
        remote="${2:-}"
        shift 2
        ;;
      --host)
        host="${2:-}"
        shift 2
        ;;
      *) break ;;
    esac
  done
  if [ -z "$remote" ]; then
    out="$(cat /etc/nixhold/fleet.pub 2>/dev/null || true)"
  else
    local hostargs=()
    [ -n "$host" ] && hostargs=(--host "$host")
    out="$(nh_ssh_sudo "$remote" "${hostargs[@]}" -- \
      'cat /etc/nixhold/fleet.pub 2>/dev/null || true' </dev/null)" || return 2
  fi
  out="$(printf '%s\n' "$out" | awk 'NF { print; exit }')"
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

# nh_fleet_key_sync [--remote …] [--host <name>] — make the machine
# hold the fleet key the repo names. Reads /etc/nixhold/fleet.pub,
# compares it with keys/fleet.pub, and installs only on a mismatch —
# so the operator's route (a passphrase prompt, a token touch) is
# opened exactly when there is something to install, and a routine
# deploy costs nothing.
nh_fleet_key_sync() {
  local want live rc=0
  want="$(nh_fleet_pub_line)" || {
    nh_err "this fleet has no keys/fleet.pub — 'nixhold secret rekey' mints the fleet key"
    return 1
  }
  live="$(nh_fleet_key_read_pub "$@")" || rc=$?
  case "$rc" in
    0)
      if [ "$live" = "$want" ]; then
        return 0
      fi
      nh_info "the machine holds a different fleet key than the repo names — installing the current one"
      ;;
    1) nh_info "the machine holds no fleet key yet — installing it" ;;
    *)
      nh_err "could not read /etc/nixhold/fleet.pub on the target"
      return 1
      ;;
  esac
  nh_fleet_key_install "$@"
}

# ---------------------------------------------------------------------
# Host SSH keys: identity for known_hosts, nothing more.

# nh_committed_host_pub <host> — path (existing or not) of the host's
# committed SSH pubkey. Non-zero only when layout can't be probed.
nh_committed_host_pub() {
  local keys_dir
  keys_dir="$(nh_worktree_keys_dir)" || return 2
  printf '%s/hosts/%s.pub' "$keys_dir" "$1"
}

# nh_derive_host_pub <privkey-path> — write <privkey-path>.pub from the
# private key.
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

# nh_generate_host_key <name> <dir> — a fresh ed25519 host key for
# <name> in <dir> (0600 + its .pub). Host keys are random per install:
# nothing recovers this one, and nothing needs to — it is a machine
# identity for known_hosts, never a recipient of anything.
nh_generate_host_key() {
  local name="$1" dir="$2"
  nh_require_cmd ssh-keygen || return 1
  mkdir -p "$dir" || {
    nh_err "could not create the staging directory $dir"
    return 1
  }
  rm -f "$dir/ssh_host_ed25519_key" "$dir/ssh_host_ed25519_key.pub"
  if ! ssh-keygen -q -t ed25519 -N "" -C "nixhold-host-$name" \
    -f "$dir/ssh_host_ed25519_key" >/dev/null 2>&1; then
    nh_err "could not generate a host SSH key for $name in $dir"
    return 1
  fi
  chmod 0600 "$dir/ssh_host_ed25519_key" || return 1
}

# nh_commit_host_pub <host> <pubkey-line-or-file> — write
# keys/hosts/<host>.pub and stage it. The single writer of that file,
# so the roster and the pin can never disagree about where it lives.
# Prints the path on stdout.
nh_commit_host_pub() {
  local host="$1" src="$2" out keys_dir root
  keys_dir="$(nh_worktree_keys_dir)" || return 2
  out="$keys_dir/hosts/$host.pub"
  mkdir -p "$keys_dir/hosts" || {
    nh_err "could not create $keys_dir/hosts"
    return 1
  }
  if [ -f "$src" ]; then
    cp "$src" "$out.tmp" || {
      rm -f "$out.tmp"
      nh_err "could not stage $host's pubkey at $out"
      return 1
    }
  else
    printf '%s\n' "$src" >"$out.tmp" || {
      rm -f "$out.tmp"
      nh_err "could not stage $host's pubkey at $out"
      return 1
    }
  fi
  if ! awk 'NF >= 2 { found = 1 } END { exit(found ? 0 : 1) }' "$out.tmp"; then
    rm -f "$out.tmp"
    nh_err "no SSH pubkey line for $host — $out NOT written"
    return 1
  fi
  mv "$out.tmp" "$out" || {
    rm -f "$out.tmp"
    nh_err "could not write $out"
    return 1
  }
  chmod 0644 "$out"
  root="$(nh_fleet_root)" || return 0
  nh_stage_for_eval "$root" "$out"
  printf '%s' "$out"
}

# nh_key_target <name> [remote] — where a verb that touches a host's
# LIVE key should act: prints an ssh target, or nothing at all for
# "this machine". Non-zero when neither applies.
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
  here="$(nh_hostname)" || here=""
  [ "$here" = "$name" ] && return 0
  if [ "$(uname -s)" = "Darwin" ] &&
    [ "$(nh_host_platform "$name" 2>/dev/null || true)" = "darwin" ]; then
    nh_warn "local hostname is '$here', not '$name' — assuming this machine IS $name"
    return 0
  fi
  return 1
}

# nh_read_live_host_pub [target] [host] — the PUBLIC half of the
# machine's /etc/ssh/ssh_host_ed25519_key, on stdout. World-readable,
# so nothing escalates: locally a `cat`, remotely a plain `nh_ssh`.
# <host> pins the connection to what the fleet already knows for it —
# which is exactly what has drifted when this verb is being run, so a
# pin failure is reported by ssh and the operator reconciles on the
# machine.
nh_read_live_host_pub() {
  local target="${1:-}" host="${2:-}" src="/etc/ssh/ssh_host_ed25519_key.pub" out
  if [ -z "$target" ]; then
    out="$(cat "$src" 2>/dev/null || true)"
  else
    local hostargs=()
    [ -n "$host" ] && hostargs=(--host "$host")
    out="$(nh_ssh "$target" "${hostargs[@]}" -- "cat $src 2>/dev/null || true" </dev/null)" || {
      nh_err "could not read $src on $target"
      return 1
    }
  fi
  out="$(printf '%s\n' "$out" | awk 'NF >= 2 { print; exit }')"
  if [ -z "$out" ]; then
    nh_err "no SSH host pubkey at $src${target:+ on $target} — the machine has never run sshd (on macOS: 'sudo ssh-keygen -A', or enable Remote Login)"
    return 1
  fi
  printf '%s' "$out"
}

# nh_ensure_darwin_host_key — a fresh macOS has no host key until sshd
# has run once. Mint one in place so the machine has a stable identity
# to pin, then leave the reading to the caller.
nh_ensure_darwin_host_key() {
  [ -f /etc/ssh/ssh_host_ed25519_key ] && return 0
  nh_info "this Mac has no SSH host key yet — generating one (ssh-keygen -A)"
  nh_sudo ssh-keygen -A >/dev/null 2>&1 || {
    nh_err "could not generate the host keys with 'ssh-keygen -A'"
    return 1
  }
  [ -f /etc/ssh/ssh_host_ed25519_key ] || {
    nh_err "'ssh-keygen -A' left no /etc/ssh/ssh_host_ed25519_key"
    return 1
  }
}
