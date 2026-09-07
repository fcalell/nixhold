# Secrets helpers shared by `nixhold secret *` and the required-secret
# walk `deploy` / `host install` run.
#
# ONE recipient set for the whole fleet: every line of
# `keys/operator.pub` plus the line in `keys/fleet.pub`. It does not
# vary per host and it does not vary per secret, so nothing here
# computes a union, keeps a sidecar, or widens a ciphertext when a
# host joins. Scope is a PATH choice only — `secrets/<name>.age` for a
# fleet secret, `secrets/<host>/<name>.age` for a host one, so two
# hosts running the same service do not collide.
#
# Encryption/decryption is plain `age`: there is no agenix-CLI
# dependency and no committed `secrets.nix` — the recipient set is the
# contract, computed fresh each invocation. agenix-the-module owns
# activation-time decryption separately, with
# `age.identityPaths = [ "/etc/nixhold/fleet.key" ]`.

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
nh_worktree_hosts_dir() { nh_worktree_layout_dir hostsDir hosts; }

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

# nh_pubkey_lines <file> -> EVERY non-empty, non-comment line of a
# committed pubkey file, one per line. The operator recipient file and
# keys/login.pub are both lists: the operator reaches their secrets by
# however many routes they hold (token, passphrase identity, or both),
# and every ssh key that may log in is a line of its own. Non-zero when
# the file is absent or holds no key line at all.
nh_pubkey_lines() {
  local f="$1" line found=1
  [ -f "$f" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in
      '' | '#'*) continue ;;
    esac
    printf '%s\n' "$line"
    found=0
  done <"$f"
  return "$found"
}

# nh_login_pub_file -> keys/login.pub (existing or not). The ONE login
# mechanism: `nixhold.fleet.derived.operatorAuthorizedKeys` is its
# lines, authorized on the operator account of every host and on the
# ISO's root.
nh_login_pub_file() {
  local keys_dir
  keys_dir="$(nh_worktree_keys_dir)" || return 2
  printf '%s/login.pub' "$keys_dir"
}

# ---------------------------------------------------------------------
# Scope: a path choice. A host secret is one ciphertext per host under
# `secrets/<host>/`; a fleet secret is ONE ciphertext under
# `secrets/`. Both carry the same recipients. The eval side derives
# `sourceFile` from the same rule, but it is a store path: the CLI
# writes in the worktree, so the split is re-derived here from `scope`
# + the worktree secrets dir.

# nh_host_secrets <host> [platform] — `nixhold.secrets` of a host as
# JSON, memoized per CLI process under the scratch root. `secret list`,
# lint and the walks all read the same declarations several times; the
# memo is a file, not a variable, so command-substitution subshells
# share it. Declarations do not move mid-verb — a verb that rewrites
# the roster drops the memo through nh_fleet_view_reset.
nh_host_secrets() {
  local host="$1" platform="${2:-}" root memo json
  root="$(nh_tmp_root)" || return 1
  memo="$root/secrets.$host.json"
  if [ -s "$memo" ]; then
    cat "$memo"
    return 0
  fi
  if [ -z "$platform" ]; then
    platform="$(nh_host_platform "$host")" || return 1
  fi
  json="$(nh_host_eval "$host" "$platform" nixhold.secrets)" || return 1
  printf '%s' "$json" >"$memo" || return 1
  printf '%s' "$json"
}

# nh_secret_scope <secrets-json> <name> — "host" | "fleet" (defaulting
# to host for a JSON that predates the field).
nh_secret_scope() {
  printf '%s' "$1" | jq -r --arg n "$2" '.[$n].scope // "host"'
}

# nh_secret_file <secrets-dir> <host> <name> <scope> — where the
# ciphertext lives in the worktree.
nh_secret_file() {
  local sdir="$1" host="$2" name="$3" scope="$4"
  if [ "$scope" = "fleet" ]; then
    printf '%s/%s.age' "$sdir" "$name"
  else
    printf '%s/%s/%s.age' "$sdir" "$host" "$name"
  fi
}

# nh_secret_declarers <name> — every host that declares <name>, as
# "<host>\t<scope>" lines. The fleet-wide question `secret list` and
# `secret edit <name>` both ask; a host's own eval can only answer for
# itself. Non-zero when at least one host could not be evaluated (the
# answer would then be short, which is exactly what must not pass
# silently).
nh_secret_declarers() {
  local name="$1" host json rc=0
  while IFS= read -r host; do
    [ -n "$host" ] || continue
    if ! json="$(nh_host_secrets "$host" 2>/dev/null)"; then
      nh_warn "could not evaluate nixhold.secrets for $host — it is left out of the answer for '$name'"
      rc=1
      continue
    fi
    printf '%s' "$json" | jq -r --arg n "$name" --arg h "$host" \
      'select(has($n)) | [ $h, (.[$n].scope // "host") ] | @tsv'
  done < <(nh_all_hosts)
  return "$rc"
}

# The worktree inputs of the recipient set. Probed once per shell: each
# costs a nix eval, and a provisioning walk validates once per secret.
# A subshell inherits the memo but cannot export it back, so a caller
# that encrypts inside per-secret subshells warms it first (see
# nh_secret_provision).
_NH_RECIPIENT_PROBED=""
_NH_OP_RECIPIENT_FILE=""
_NH_OP_RECIPIENT_KEYS=""
_NH_KEYS_DIR=""
nh_probe_recipient_inputs() {
  [ -z "$_NH_RECIPIENT_PROBED" ] || return 0
  _NH_RECIPIENT_PROBED="done"
  _NH_OP_RECIPIENT_FILE="$(nh_worktree_layout_file ageRecipient 2>/dev/null)" || _NH_OP_RECIPIENT_FILE=""
  if [ -n "$_NH_OP_RECIPIENT_FILE" ]; then
    # EVERY line, not the first: the operator may hold a token
    # recipient and a passphrase-identity recipient at once, and a
    # ciphertext that carries only one of them is openable by only one
    # of the operator's two seats.
    _NH_OP_RECIPIENT_KEYS="$(nh_pubkey_lines "$_NH_OP_RECIPIENT_FILE")" || _NH_OP_RECIPIENT_KEYS=""
  fi
  _NH_KEYS_DIR="$(nh_worktree_keys_dir 2>/dev/null)" || _NH_KEYS_DIR=""
}

# nh_recipients_file <out> — THE recipient set, one line per recipient,
# for `age -R`: every operator line plus the fleet key's. The same set
# for every secret in the fleet, which is why nothing here takes a host
# or a name.
#
# The fleet key is minted when the fleet has none: a fleet whose first
# secret is being written has no fleet.pub yet, and a ciphertext
# encrypted to the operator alone would be one no host could read.
nh_recipients_file() {
  local out="$1" fleet_line
  nh_probe_recipient_inputs
  if [ -z "$_NH_OP_RECIPIENT_KEYS" ]; then
    nh_err "no operator recipient to encrypt to (${_NH_OP_RECIPIENT_FILE:-nixhold.layout.ageRecipient could not be probed}) — 'nixhold host add' generates the operator identity on a fleet that has none"
    return 1
  fi
  nh_fleet_key_ensure || return 1
  fleet_line="$(nh_fleet_pub_line)" || {
    nh_err "no fleet recipient at $(nh_fleet_pub_file 2>/dev/null) — refusing to encrypt to the operator alone (no host could decrypt it)"
    return 1
  }
  : >"$out" || return 1
  printf '%s\n' "$_NH_OP_RECIPIENT_KEYS" >>"$out" || return 1
  printf '%s\n' "$fleet_line" >>"$out" || return 1
  # Every writer of this file hands it straight to `age -R`, and a
  # token recipient in it needs the plugin present to encrypt at all —
  # refused here, once, rather than in each call site.
  nh_age_require_encrypt
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

# nh_login_pub_default_from_identity <plaintext-key-file> — the one
# place `keys/login.pub` is written by the CLI. The framework-declared
# `identity` secret is the fleet's outbound SSH key; on a fleet with no
# token in the picture it is also the key the operator logs in with, so
# a login.pub that is missing or holds no key line gets that pubkey
# APPENDED (comments the operator put there survive). A login.pub that
# already names a key is never touched: a token fleet lists its sk keys
# there by hand, and overwriting that would lock the operator out.
#
# Called wherever the identity plaintext is in hand — the provisioning
# walk pre-encryption, `secret edit identity` and `secret rekey`
# post-decryption — so the operator never hand-copies a pubkey.
nh_login_pub_default_from_identity() {
  local plain="$1" out root d
  if [ ! -s "$plain" ]; then
    nh_warn "no plaintext for the identity secret — keys/login.pub NOT written"
    return 1
  fi
  out="$(nh_login_pub_file)" || return 0
  if nh_pubkey_lines "$out" >/dev/null 2>&1; then
    return 0
  fi
  d="$(nh_tmpdir loginpub)" || return 1
  chmod 600 "$plain" 2>/dev/null || true
  if ! ssh-keygen -y -f "$plain" >"$d/line" 2>/dev/null; then
    nh_warn "the identity secret is not a valid SSH private key — $out NOT written"
    return 1
  fi
  mkdir -p "$(dirname "$out")" || return 1
  if ! cat "$d/line" >>"$out"; then
    nh_err "could not append the identity pubkey to $out"
    return 1
  fi
  chmod 0644 "$out" 2>/dev/null || true
  nh_ok "authorized the fleet identity in $out — every host and the ISO let that key in"
  root="$(nh_fleet_root)" || return 0
  nh_stage_for_eval "$root" "$out"
}

# ---------------------------------------------------------------------
# The operator's route into a ciphertext.
#
# The operator seat is a FIDO2 token (age-plugin-fido2-hmac), a
# passphrase-wrapped identity (keys/operator.age), or both. There is no
# mode flag: the committed files decide. keys/operator.pub
# (layout.ageRecipient) holds ONE RECIPIENT PER LINE — a token
# recipient starts with `age1fido2-hmac1`, the wrapped identity's is a
# plain `age1…` — and everything the operator can read is encrypted
# with `age -R` over that whole file, so each seat gets its own stanza
# and either one opens the ciphertext.
#
# Encryption never needs the token: a v2 fido2-hmac recipient carries
# the X25519 public half, so `age -R` wraps the file key in the
# token's absence. It DOES need the plugin binary on PATH — age
# refuses a recipient whose plugin it cannot spawn — which is why the
# CLI ships it (cli/default.nix).

# The plugin binary and the device-listing tool, named once.
NIXHOLD_AGE_PLUGIN="age-plugin-fido2-hmac"
NIXHOLD_AGE_PLUGIN_NAME="fido2-hmac"

# nh_age_has_token_recipient — does the operator recipients file hold a
# token line? Reads the probe's memo, so it costs no extra eval.
nh_age_has_token_recipient() {
  nh_probe_recipient_inputs
  [ -n "$_NH_OP_RECIPIENT_KEYS" ] || return 1
  printf '%s\n' "$_NH_OP_RECIPIENT_KEYS" | grep -q '^age1fido2-hmac1'
}

# nh_age_token_present — is a FIDO2 token reachable RIGHT NOW? Both
# halves are needed: the plugin age would spawn, and a device for it to
# talk to. `age -d -j fido2-hmac` with nothing plugged in blocks until
# its own timeout, so this is what keeps the route choice instant.
nh_age_token_present() {
  command -v "$NIXHOLD_AGE_PLUGIN" >/dev/null 2>&1 || return 1
  command -v fido2-token >/dev/null 2>&1 || return 1
  [ -n "$(fido2-token -L 2>/dev/null)" ]
}

# nh_age_wrapped_identity -> path of the passphrase-wrapped operator
# identity, or non-zero when this checkout has none.
# $NIXHOLD_IDENTITY_FILE (the ISO bakes a copy) wins over the
# fleet-committed `layout.ageIdentityWrapped`, which is `null` on a
# token-only fleet — an absent value, not an error.
nh_age_wrapped_identity() {
  local src="${NIXHOLD_IDENTITY_FILE:-}"
  if [ -n "$src" ] && [ -f "$src" ]; then
    printf '%s' "$src"
    return 0
  fi
  src="$(nh_worktree_layout_file ageIdentityWrapped 2>/dev/null)" || return 1
  [ -n "$src" ] && [ -f "$src" ] || return 1
  printf '%s' "$src"
}

# nh_age_pick_route [--bulk] — decide, ONCE per shell, which route
# decrypts, and leave it in $_NH_AGE_ROUTE ("token" or "passphrase").
# Non-zero when this checkout has neither. A global rather than a
# stdout value on purpose: command substitution would run it in a
# subshell, losing both the memo and the stickiness that keeps a failed
# token from silently turning into a passphrase prompt half way through
# a verb.
#
# The token wins only when the fleet actually names one AND one is
# plugged in — a token recipient with the device in a drawer falls to
# the passphrase, which is the whole point of committing both.
#
# --bulk inverts that preference for the verbs that open EVERY
# ciphertext (`secret rekey`, `secret rotate`): a passphrase is one
# prompt for the whole walk, a token is one touch per file. It is an
# argument to the picker, not a flag the operator passes: which verb is
# bulk is a property of the verb.
#
# The last clause is the bootstrap path (`host install --repo/--keys`,
# the ISO's clone key): there is no checkout to read recipients from
# yet, so a visible token is the only evidence there is.
_NH_AGE_ROUTE=""
nh_age_pick_route() {
  local bulk=0
  [ "${1:-}" = "--bulk" ] && bulk=1
  case "$_NH_AGE_ROUTE" in
    token | passphrase) return 0 ;;
    -) return 1 ;;
  esac
  if [ "$bulk" -eq 1 ] && nh_age_wrapped_identity >/dev/null; then
    _NH_AGE_ROUTE="passphrase"
    nh_info "decrypting with the passphrase identity (one prompt for the whole walk)"
    return 0
  fi
  if nh_age_has_token_recipient && nh_age_token_present; then
    _NH_AGE_ROUTE="token"
    nh_info "decrypting with the hardware token (touch it when it blinks; the plugin asks for the PIN if the credential requires one)"
    return 0
  fi
  if nh_age_wrapped_identity >/dev/null; then
    _NH_AGE_ROUTE="passphrase"
    nh_info "decrypting with the passphrase identity"
    return 0
  fi
  if [ -z "$_NH_OP_RECIPIENT_KEYS" ] && nh_age_token_present; then
    _NH_AGE_ROUTE="token"
    nh_info "decrypting with the hardware token (no fleet recipients to read yet — the token is what is here)"
    return 0
  fi
  _NH_AGE_ROUTE="-"
  return 1
}

# nh_age_route_check [<what>] [--bulk] — is there ANY way to decrypt
# here? Answers without unwrapping anything and without touching the
# token, so a verb that must fail EARLY — rekey ahead of its loop,
# `host install`'s preflight — keeps that property now that the unwrap
# is lazy.
nh_age_route_check() {
  local what="" bulk=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --bulk) bulk=(--bulk) ;;
      *) what="$1" ;;
    esac
    shift
  done
  nh_age_pick_route "${bulk[@]}" && return 0
  nh_err "no way to decrypt${what:+ $what}: this fleet names no FIDO2 token recipient with a token plugged in (age1fido2-hmac1… in nixhold.layout.ageRecipient), and this checkout holds no passphrase-wrapped identity (nixhold.layout.ageIdentityWrapped / \$NIXHOLD_IDENTITY_FILE) — plug the token in, or restore keys/operator.age"
  return 1
}

# nh_age_require_encrypt — refuse to encrypt to a token recipient with
# no plugin on PATH. The token itself is not needed (see the header
# above), but age cannot even parse the recipient without the plugin,
# and its own message names neither the fleet nor the fix.
nh_age_require_encrypt() {
  nh_age_has_token_recipient || return 0
  command -v "$NIXHOLD_AGE_PLUGIN" >/dev/null 2>&1 && return 0
  nh_err "the operator recipients include a FIDO2 token (age1fido2-hmac1…) but $NIXHOLD_AGE_PLUGIN is not on PATH — age cannot encrypt to that recipient; run this through the nixhold CLI, which ships the plugin"
  return 1
}

# nh_operator_identity_file -> path of the UNWRAPPED operator identity,
# unwrapping it (one passphrase prompt) the first time it is asked for
# in this CLI process. The plaintext lives in the process scratch root
# — $$-keyed, so subshells agree on it — which the dispatcher's
# EXIT/INT/TERM/HUP handler wipes. A verb that decrypts a dozen
# ciphertexts, or that calls another verb, therefore still costs one
# prompt.
nh_operator_identity_file() {
  local root out
  root="$(nh_tmp_root)" || return 1
  out="$root/operator-identity"
  if [ -s "$out" ]; then
    printf '%s' "$out"
    return 0
  fi
  : >"$out" || return 1
  chmod 600 "$out" || return 1
  nh_unwrap_identity "$out" || {
    rm -f "$out"
    return 1
  }
  printf '%s' "$out"
}

# nh_age_decrypt <ciphertext> <out> — the ONE decrypt in the CLI.
# Whichever route nh_age_pick_route settled on is the route: a token
# failure (wrong PIN, no touch, a ciphertext that predates the token
# recipient) is reported and returned non-zero rather than falling
# through to a passphrase prompt half way down a rekey — the operator
# re-runs. <out> exists only on success.
nh_age_decrypt() {
  local src="$1" out="$2" idfile
  nh_age_route_check "$src" || return 1
  case "$_NH_AGE_ROUTE" in
    token)
      # age -d -j hands the plugin this process's terminal for the PIN
      # prompt and the touch blink, so nothing here redirects stdin or
      # stderr.
      if ! age -d -j "$NIXHOLD_AGE_PLUGIN_NAME" -o "$out" "$src"; then
        rm -f "$out"
        nh_err "the FIDO2 token did not decrypt $src (wrong PIN, no touch, the wrong token, or a ciphertext written before the token became a recipient) — nothing fell back to the passphrase; fix it and re-run"
        return 1
      fi
      ;;
    passphrase)
      idfile="$(nh_operator_identity_file)" || return 1
      if ! age -d -i "$idfile" -o "$out" "$src"; then
        rm -f "$out"
        nh_err "the operator identity did not decrypt $src (it was encrypted to a key this checkout does not hold)"
        return 1
      fi
      ;;
    *)
      nh_err "no decrypt route for $src"
      return 1
      ;;
  esac
}

# nh_unwrap_identity <out> — decrypt the passphrase-wrapped operator
# age identity to <out> (age prompts for the passphrase on the TTY).
# Caller chmods/removes <out>; nh_operator_identity_file is the one
# that should be calling it. $NIXHOLD_IDENTITY_FILE when set (the ISO
# bakes a copy), else the fleet-committed `layout.ageIdentityWrapped`.
# Nothing here generates an identity: a ciphertext exists, so it was
# encrypted to one the operator must already hold.
#
# A typo costs a whole verb (rekey walks every ciphertext), so an
# interactive operator gets 3 attempts; age reads the passphrase from
# the controlling TTY itself, so a retry is just re-invoking it. With
# no terminal in reach there is nobody to re-prompt: fail on the first
# miss. Only an actual bad passphrase is retried — age's other
# failures (unwritable output, a ciphertext that is not
# passphrase-wrapped, EOF on the prompt) repeat identically and are
# reported verbatim, once. <out> exists only on success.
nh_unwrap_identity() {
  local out="$1" src attempts=1 n=1 errfile rc
  src="$(nh_age_wrapped_identity)" || {
    nh_err "no passphrase-wrapped operator identity: the fleet commits none at nixhold.layout.ageIdentityWrapped and \$NIXHOLD_IDENTITY_FILE is unset — plug in the operator's FIDO2 token, or restore keys/operator.age from another checkout"
    return 1
  }
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

# nh_secret_reencrypt <ciphertext> <recipients-file> <workdir> — open
# one committed ciphertext and write it back to the current recipient
# set. The shared body of `secret rekey` and `secret rotate`; the
# decrypt route was settled by the caller's nh_age_route_check, so
# nothing here re-decides it. The plaintext lives in <workdir> (under
# the process scratch root) for the length of the call and is removed
# on both paths.
#
# `identity` is the one name with a side effect: its plaintext is the
# fleet's login key, so a fleet whose keys/login.pub is missing or
# empty gets it filled in here (the migration path for a fleet that
# predates login.pub).
nh_secret_reencrypt() {
  local target="$1" rfile="$2" workdir="$3" tmp label
  label="${target##*/}"
  tmp="$workdir/plain"
  if ! nh_age_decrypt "$target" "$tmp"; then
    rm -f "$tmp"
    nh_warn "$label is not decryptable by the operator — NOT rekeyed"
    return 1
  fi
  # Encrypt to a sibling temp + rename so a failure cannot leave the
  # committed ciphertext truncated.
  if ! age -R "$rfile" -o "$target.tmp" "$tmp"; then
    rm -f "$target.tmp" "$tmp"
    nh_warn "re-encryption of $label failed — the original is untouched"
    return 1
  fi
  if ! mv "$target.tmp" "$target"; then
    rm -f "$target.tmp" "$tmp"
    nh_warn "could not replace $label — the original is untouched"
    return 1
  fi
  if [ "$label" = "identity.age" ]; then
    nh_login_pub_default_from_identity "$tmp" || true
  fi
  rm -f "$tmp"
  nh_stage_for_eval "$(nh_fleet_root)" "$target"
}

# nh_secret_ciphertexts — every committed ciphertext under the
# worktree secrets dir, one path per line: `secrets/<name>.age` (fleet
# scope) and `secrets/<host>/<name>.age` (host scope). The filesystem
# is the witness here rather than the eval — a rekey must reach a
# ciphertext whose declaration was removed just as surely as one that
# is still declared, or the fleet key rotates out from under it.
nh_secret_ciphertexts() {
  local sdir
  sdir="$(nh_worktree_secrets_dir)" || return 2
  [ -d "$sdir" ] || return 0
  find "$sdir" -mindepth 1 -maxdepth 2 -type f -name '*.age' | sort
}
