# Secrets helpers shared by `nixhold secret *` and the bootstrap
# auto-walk.
#
# Recipients come from the eval-side option
# `nixhold.secrets.<name>.recipients` (operator age key + owning host
# SSH key). Encryption/decryption is plain `age`: there is no
# agenix-CLI dependency and no committed `secrets.nix` — the recipient
# set is the contract, computed fresh each invocation. agenix-the-
# module owns activation-time decryption separately.

# nh_host_platform <host> -> prints "nixos" | "darwin"; non-zero if
# the host is in neither configuration set.
nh_host_platform() {
  local host="$1" root names
  root="$(nh_fleet_root)" || return 2
  names="$(nix eval --json --no-warn-dirty "$root#nixosConfigurations" \
    --apply 'builtins.attrNames' 2>/dev/null || echo '[]')"
  if printf '%s' "$names" | jq -e --arg h "$host" 'index($h) != null' >/dev/null 2>&1; then
    printf 'nixos'
    return 0
  fi
  names="$(nix eval --json --no-warn-dirty "$root#darwinConfigurations" \
    --apply 'builtins.attrNames' 2>/dev/null || echo '[]')"
  if printf '%s' "$names" | jq -e --arg h "$host" 'index($h) != null' >/dev/null 2>&1; then
    printf 'darwin'
    return 0
  fi
  return 1
}

# nh_all_hosts -> prints every host name (nixos then darwin), one per
# line.
nh_all_hosts() {
  local root
  root="$(nh_fleet_root)" || return 2
  {
    nix eval --json --no-warn-dirty "$root#nixosConfigurations" \
      --apply 'builtins.attrNames' 2>/dev/null || echo '[]'
    nix eval --json --no-warn-dirty "$root#darwinConfigurations" \
      --apply 'builtins.attrNames' 2>/dev/null || echo '[]'
  } | jq -r '.[]?'
}

# nh_flake_source_path -> the /nix/store path THIS fleet's own source
# copies to (what its layout.* paths evaluate under). Memoized in the
# calling shell; non-zero when it can't be probed.
_NH_FLAKE_SRC=""
nh_flake_source_path() {
  local root p
  case "$_NH_FLAKE_SRC" in
    "") ;;
    -) return 1 ;;
    *)
      printf '%s' "$_NH_FLAKE_SRC"
      return 0
      ;;
  esac
  root="$(nh_fleet_root)" || return 2
  p="$(nix flake metadata --json --no-warn-dirty "$root" 2>/dev/null | jq -r '.path // empty')" || p=""
  if [ -z "$p" ]; then
    _NH_FLAKE_SRC="-"
    return 1
  fi
  _NH_FLAKE_SRC="$p"
  printf '%s' "$p"
}

# nh_reroot_layout <layout-key> <evaluated-path> -> the operator's
# working-tree path for that layout value.
#
# layout.* options are types.path, so they eval to read-only
# /nix/store/<hash>-source/<sub> paths (correct for the activation
# side). The CLI must *write* there, so the fleet's OWN store prefix is
# swapped back for $fleet_root. A store path belonging to another flake
# input (a private secrets repo, say) has no working tree here at all:
# re-rooting it under $fleet_root would read and write a path that
# never existed, so refuse instead (exit 3, which lint reports as a
# violation rather than as a probe failure).
nh_reroot_layout() {
  local key="$1" abspath="$2" root src rest store_root
  root="$(nh_fleet_root)" || return 2
  case "$abspath" in
    "$root" | "$root"/*)
      printf '%s' "$abspath"
      return 0
      ;;
    /nix/store/*) ;;
    *)
      # Not a store path and not under the checkout: an operator-set
      # absolute path, used verbatim.
      printf '%s' "$abspath"
      return 0
      ;;
  esac
  rest="${abspath#/nix/store/}"
  store_root="/nix/store/${rest%%/*}"
  src="$(nh_flake_source_path)" || src=""
  # The metadata probe and the eval can land on two copies of the same
  # tree (a write between the calls re-hashes it), so a store root
  # whose flake.nix is byte-identical to ours is still ours.
  if [ "$store_root" != "$src" ] && ! cmp -s "$store_root/flake.nix" "$root/flake.nix"; then
    nh_err "nixhold.layout.$key points into another flake input ($abspath); the CLI only writes inside the fleet checkout ($root)"
    return 3
  fi
  if [ "$abspath" = "$store_root" ]; then
    printf '%s' "$root"
  else
    printf '%s/%s' "$root" "${abspath#"$store_root"/}"
  fi
}

# nh_worktree_layout_dir <layout-key> <fallback-subdir> -> the
# operator's working-tree directory for nixhold.layout.<key>; the
# fallback stands in when the option can't be probed at all.
nh_worktree_layout_dir() {
  local key="$1" fallback="$2" root abspath out
  root="$(nh_fleet_root)" || return 2
  abspath="$(nh_layout "$key" 2>/dev/null | jq -r '.')" || abspath=""
  if [ -z "$abspath" ] || [ "$abspath" = "null" ]; then
    printf '%s/%s' "$root" "$fallback"
    return 0
  fi
  out="$(nh_reroot_layout "$key" "$abspath")" || return $?
  printf '%s' "$out"
}

nh_worktree_secrets_dir() { nh_worktree_layout_dir secrets secrets; }
nh_worktree_keys_dir() { nh_worktree_layout_dir keysDir keys; }

# nh_worktree_layout_file <layout-key> -> worktree path for a
# file-valued nixhold.layout.<key>; non-zero (and no output) when the
# option can't be probed or points outside the fleet checkout.
nh_worktree_layout_file() {
  local key="$1" abspath out
  nh_fleet_root >/dev/null || return 2
  abspath="$(nh_layout "$key" 2>/dev/null | jq -r '.')" || abspath=""
  if [ -z "$abspath" ] || [ "$abspath" = "null" ]; then
    return 1
  fi
  out="$(nh_reroot_layout "$key" "$abspath")" || return $?
  printf '%s' "$out"
}

# nh_pubkey_line <file> -> the first non-empty, non-comment line of a
# committed pubkey file (age recipient or SSH host pubkey). Non-zero
# when the file is absent or holds no key line.
nh_pubkey_line() {
  local f="$1" line
  [ -f "$f" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in
      '' | '#'*) continue ;;
    esac
    printf '%s' "$line"
    return 0
  done <"$f"
  return 1
}

# nh_host_has_ciphertexts <host> — does the host already own .age files
# in the worktree? Tri-state, because the answer gates a refusal:
#   0  yes, at least one
#   1  no, none
#   2  cannot tell (the secrets directory could not be resolved)
# Collapsing 2 into 1 would turn a transient probe failure into
# "encrypt to the operator alone", which is the outcome the caller
# exists to prevent.
nh_host_has_ciphertexts() {
  local host="$1" sdir f
  sdir="$(nh_worktree_secrets_dir 2>/dev/null)" || return 2
  for f in "$sdir/hosts/$host"/*.age; do
    if [ -e "$f" ]; then
      return 0
    fi
  done
  return 1
}

# The two worktree inputs of the recipient check. Probed once per
# shell: each costs a nix eval, and bootstrap/rekey validate once per
# secret. A shell inherits the memo but cannot export it back, so a
# caller that validates inside a per-secret subshell warms it first
# (see cmd_secret_bootstrap).
_NH_RECIPIENT_PROBED=""
_NH_OP_RECIPIENT_FILE=""
_NH_OP_RECIPIENT_KEY=""
_NH_KEYS_DIR=""
nh_probe_recipient_inputs() {
  [ -z "$_NH_RECIPIENT_PROBED" ] || return 0
  _NH_RECIPIENT_PROBED="done"
  _NH_OP_RECIPIENT_FILE="$(nh_worktree_layout_file ageRecipient 2>/dev/null)" || _NH_OP_RECIPIENT_FILE=""
  if [ -n "$_NH_OP_RECIPIENT_FILE" ]; then
    _NH_OP_RECIPIENT_KEY="$(nh_pubkey_line "$_NH_OP_RECIPIENT_FILE")" || _NH_OP_RECIPIENT_KEY=""
  fi
  _NH_KEYS_DIR="$(nh_worktree_keys_dir 2>/dev/null)" || _NH_KEYS_DIR=""
}

# nh_check_recipients <recipients-file> <host> [<secret-name>] — refuse
# a recipient set that would lock somebody out.
#
# The eval side builds `nixhold.secrets.<n>.recipients` behind
# pathExists guards, and an UNTRACKED keys/hosts/<host>/host.pub is
# invisible to `nix eval` — so the normal failure mode is a silently
# short list, not an empty one. Encrypting to the operator alone leaves
# the host unable to decrypt at activation (and a rekey would do that
# to every secret it owns at once), so both halves are checked by
# value, not by count.
nh_check_recipients() {
  local rfile="$1" host="$2" name="${3:-}" label root host_pub host_key
  label="$host${name:+/$name}"
  root="$(nh_fleet_root)" || return 2
  if [ ! -s "$rfile" ]; then
    nh_err "$label has no recipients — commit the operator recipient (nixhold.layout.ageRecipient) and keys/hosts/$host/host.pub, then re-run"
    return 1
  fi

  nh_probe_recipient_inputs
  if [ -z "$_NH_OP_RECIPIENT_KEY" ]; then
    nh_err "$label: no operator recipient to encrypt to (${_NH_OP_RECIPIENT_FILE:-nixhold.layout.ageRecipient could not be probed}) — run 'nixhold init' and commit the operator pubkey"
    return 1
  fi
  if ! grep -qxF -- "$_NH_OP_RECIPIENT_KEY" "$rfile"; then
    nh_err "$label: the operator recipient in $_NH_OP_RECIPIENT_FILE is not in the evaluated recipient set — nix eval cannot see an untracked file; run: git -C \"$root\" add --intent-to-add \"$_NH_OP_RECIPIENT_FILE\""
    return 1
  fi

  if [ -z "$_NH_KEYS_DIR" ]; then
    nh_err "$label: nixhold.layout.keysDir could not be probed — cannot verify that $host is a recipient of its own secrets"
    return 1
  fi
  host_pub="$_NH_KEYS_DIR/hosts/$host/host.pub"
  if host_key="$(nh_pubkey_line "$host_pub")"; then
    if ! grep -qxF -- "$host_key" "$rfile"; then
      nh_err "$label: $host_pub exists but is not in the evaluated recipient set — nix eval cannot see an untracked file; run: git -C \"$root\" add --intent-to-add \"$host_pub\""
      return 1
    fi
    return 0
  fi
  local owns=0
  nh_host_has_ciphertexts "$host" || owns=$?
  case "$owns" in
    0)
      nh_err "$label: no readable $host_pub, yet $host already owns encrypted secrets — refusing to encrypt to the operator alone (the host could no longer decrypt at activation). Restore its pubkey, or run 'nixhold host rotate-key $host'."
      return 1
      ;;
    1) ;;
    *)
      nh_err "$label: no readable $host_pub, and whether $host already owns encrypted secrets could not be determined (nixhold.layout.secrets is not resolvable here) — refusing to encrypt to the operator alone on a guess. Fix the fleet checkout, then re-run."
      return 1
      ;;
  esac
  nh_warn "$label: no $host_pub yet — encrypting to the operator only; commit the host key and run 'nixhold secret rekey' before $host can decrypt it"
}

# nh_recipients_file <secrets-json> <host> <name> <out> — write the
# secret's age recipients (one per line) for `age -R`, after checking
# the set is complete. Errors if the secret is undeclared.
nh_recipients_file() {
  local json="$1" host="$2" name="$3" out="$4"
  if ! printf '%s' "$json" | jq -e --arg n "$name" 'has($n)' >/dev/null 2>&1; then
    nh_err "secret '$name' is not declared on $host (add nixhold.secrets.$name first)"
    return 1
  fi
  if ! printf '%s' "$json" | jq -r --arg n "$name" '.[$n].recipients[]' >"$out"; then
    nh_err "could not read the recipients of $host/$name"
    return 1
  fi
  nh_check_recipients "$out" "$host" "$name"
}

# nh_editor_cmd -> the editor command line the operator has set, for
# announcing it before the screen is seized. VISUAL wins over EDITOR
# (the usual precedence: VISUAL is the full-screen one), vi is the
# floor.
nh_editor_cmd() {
  local spec="${VISUAL:-}"
  [ -n "${spec//[[:space:]]/}" ] || spec="${EDITOR:-}"
  [ -n "${spec//[[:space:]]/}" ] || spec="vi"
  printf '%s' "$spec"
}

# nh_run_editor <file> — open the operator's editor on <file>.
# $VISUAL/$EDITOR are command LINES, not program names ("code --wait",
# "emacsclient -nw", "nvim -c 'set noswapfile'"), so the spec is
# evaluated as one; the filename is passed as a positional so it is
# never re-split or glob-expanded.
nh_run_editor() {
  # shellcheck disable=SC2034 # $file is expanded by the eval below
  local file="$1" spec
  spec="$(nh_editor_cmd)"
  if ! eval "$spec \"\$file\""; then
    nh_err "editor ($spec) exited non-zero — nothing was encrypted"
    return 1
  fi
}

# nh_commit_identity_pub <host> <plaintext-key-file> — derive the
# pubkey of the host's `sshIdentity = true` secret and commit it as
# keys/hosts/<host>/identity.pub — the eval-time default for
# `fleet.hosts.<host>.loginPubkey`. Called by bootstrap (plaintext in
# hand pre-encryption) and rekey (plaintext in hand post-decryption),
# so the operator never hand-copies pubkeys. Warns (non-fatal) when
# the plaintext is not a valid SSH private key.
nh_commit_identity_pub() {
  local host="$1" plain="$2" keys_dir out root
  # An absent/empty plaintext means the decrypt (or the generator)
  # already failed: refuse before ssh-keygen turns that into a
  # misleading "not a valid SSH private key".
  if [ ! -s "$plain" ]; then
    nh_warn "no plaintext for the sshIdentity secret on $host — identity.pub NOT written"
    return 1
  fi
  keys_dir="$(nh_worktree_keys_dir)" || return 0
  out="$keys_dir/hosts/$host/identity.pub"
  mkdir -p "$keys_dir/hosts/$host"
  chmod 600 "$plain" 2>/dev/null || true
  if ! ssh-keygen -y -f "$plain" >"$out.tmp" 2>/dev/null; then
    rm -f "$out.tmp"
    nh_warn "sshIdentity secret on $host is not a valid SSH private key — $out NOT written"
    return 1
  fi
  mv "$out.tmp" "$out"
  nh_ok "committed operator identity pubkey to $out"
  # Stage so dirty-flake eval sees it (same reason host-add stages
  # host.pub — untracked files are invisible to nix eval).
  root="$(nh_fleet_root)" || return 0
  git -C "$root" add --intent-to-add "$out" 2>/dev/null ||
    nh_warn "git add of $out failed — 'git add' it before evaluating"
}

# nh_unwrap_identity <out> — decrypt the passphrase-wrapped operator
# age identity to <out> (age prompts for the passphrase on the TTY).
# Caller chmods/removes <out>. Prefers the operator-local copy; falls
# back to the fleet-committed `layout.ageIdentityWrapped`, so a fresh
# clone edits secrets without ever running `nixhold init` (both copies
# are passphrase-wrapped, so the fallback costs nothing in security —
# it only costs a prompt per invocation instead of per machine).
#
# A typo costs a whole verb (rekey walks every host), so an
# interactive operator gets 3 attempts; age reads the passphrase from
# the controlling TTY itself, so a retry is just re-invoking it. With
# no terminal in reach there is nobody to re-prompt: fail on the first
# miss. Only an actual bad passphrase is retried — age's other
# failures (unwritable output, a ciphertext that is not
# passphrase-wrapped, EOF on the prompt) repeat identically and are
# reported verbatim, once. <out> exists only on success.
nh_unwrap_identity() {
  local out="$1" src="$NIXHOLD_IDENTITY_FILE" committed attempts=1 n=1 errfile rc
  if [ ! -f "$src" ]; then
    committed="$(nh_worktree_layout_file ageIdentityWrapped)" || committed=""
    if [ -z "$committed" ] || [ ! -f "$committed" ]; then
      nh_err "no operator identity at $NIXHOLD_IDENTITY_FILE and no committed one in reach — run 'nixhold init', or run this from a fleet checkout that commits layout.ageIdentityWrapped"
      return 1
    fi
    nh_info "no $NIXHOLD_IDENTITY_FILE — using the fleet-committed identity $committed ('nixhold init' persists it locally)"
    src="$committed"
  fi
  if [ -t 0 ] || [ -t 2 ]; then
    attempts=3
  fi
  # age prompts on the controlling terminal, not on stderr, so its
  # stderr can be captured without eating the prompt.
  errfile="$(mktemp -t nixhold-age.XXXXXX)" || {
    nh_err "could not create a temp file for age's diagnostics"
    return 1
  }
  while :; do
    nh_info "unlock operator identity (passphrase prompt)"
    rc=0
    age -d -o "$out" "$src" 2>"$errfile" || rc=$?
    if [ "$rc" -eq 0 ]; then
      rm -f "$errfile"
      return 0
    fi
    rm -f "$out"
    if ! grep -qi 'incorrect passphrase' "$errfile"; then
      if [ -s "$errfile" ]; then
        cat "$errfile" >&2
      fi
      rm -f "$errfile"
      nh_err "age failed while unwrapping the operator identity at $src (not a passphrase failure — see above)"
      return 1
    fi
    if [ "$n" -ge "$attempts" ]; then
      break
    fi
    nh_err "incorrect passphrase — $((attempts - n)) attempt(s) left"
    n=$((n + 1))
  done
  rm -f "$errfile"
  nh_err "could not unlock the operator identity at $src — wrong passphrase"
  return 1
}
