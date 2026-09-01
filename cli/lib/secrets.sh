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

# nh_worktree_layout_dir <layout-key> <fallback-subdir> -> the
# operator's working-tree directory for nixhold.layout.<key>.
#
# layout.* options are types.path, so they eval to read-only
# /nix/store/<hash>-source/<sub> paths (correct for the activation
# side). The CLI must *write* there, so recover the repo-relative
# subpath (strip the store prefix) and re-root it under $fleet_root.
nh_worktree_layout_dir() {
  local key="$1" fallback="$2" root abspath rel
  root="$(nh_fleet_root)" || return 2
  abspath="$(nh_layout "$key" 2>/dev/null | jq -r '.')" || abspath=""
  if [ -z "$abspath" ] || [ "$abspath" = "null" ]; then
    printf '%s/%s' "$root" "$fallback"
    return 0
  fi
  case "$abspath" in
    /nix/store/*) rel="${abspath#/nix/store/*/}" ;;
    "$root"/*) rel="${abspath#"$root"/}" ;;
    *) rel="$abspath" ;;
  esac
  case "$rel" in
    /*) printf '%s/%s' "$root" "$fallback" ;;
    *) printf '%s/%s' "$root" "$rel" ;;
  esac
}

nh_worktree_secrets_dir() { nh_worktree_layout_dir secrets secrets; }
nh_worktree_keys_dir() { nh_worktree_layout_dir keysDir keys; }

# nh_worktree_layout_file <layout-key> -> worktree path for a
# file-valued nixhold.layout.<key>; non-zero (and no output) when the
# option can't be probed. Same store-prefix re-rooting as the dir
# variant.
nh_worktree_layout_file() {
  local key="$1" root abspath rel
  root="$(nh_fleet_root)" || return 2
  abspath="$(nh_layout "$key" 2>/dev/null | jq -r '.')" || abspath=""
  if [ -z "$abspath" ] || [ "$abspath" = "null" ]; then
    return 1
  fi
  case "$abspath" in
    /nix/store/*) rel="${abspath#/nix/store/*/}" ;;
    "$root"/*) rel="${abspath#"$root"/}" ;;
    *) rel="$abspath" ;;
  esac
  case "$rel" in
    /*) printf '%s' "$rel" ;;
    *) printf '%s/%s' "$root" "$rel" ;;
  esac
}

# nh_recipients_file <secrets-json> <name> <out> — write the secret's
# age recipients (one per line) for `age -R`. Errors if the secret is
# undeclared or has no recipients.
nh_recipients_file() {
  local json="$1" name="$2" out="$3"
  if ! printf '%s' "$json" | jq -e --arg n "$name" 'has($n)' >/dev/null 2>&1; then
    nh_err "secret '$name' is not declared (add nixhold.secrets.$name first)"
    return 1
  fi
  printf '%s' "$json" | jq -r --arg n "$name" '.[$n].recipients[]' >"$out"
  if [ ! -s "$out" ]; then
    nh_err "secret '$name' has no recipients — commit keys/operator.pub and the host key"
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
# miss. <out> exists only on success.
nh_unwrap_identity() {
  local out="$1" src="$NIXHOLD_IDENTITY_FILE" committed attempts=1 n=1
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
  while :; do
    nh_info "unlock operator identity (passphrase prompt)"
    if age -d -o "$out" "$src"; then
      return 0
    fi
    rm -f "$out"
    if [ "$n" -ge "$attempts" ]; then
      break
    fi
    nh_err "incorrect passphrase — $((attempts - n)) attempt(s) left"
    n=$((n + 1))
  done
  nh_err "could not unlock the operator identity at $src"
  return 1
}
