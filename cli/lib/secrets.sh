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

# nh_unwrap_identity <out> — decrypt the passphrase-wrapped operator
# age identity to <out> (prompts for the passphrase). Caller chmods/
# removes <out>.
nh_unwrap_identity() {
  local out="$1"
  if [ ! -f "$NIXHOLD_IDENTITY_FILE" ]; then
    nh_err "no operator identity at $NIXHOLD_IDENTITY_FILE — run 'nixhold init'"
    return 1
  fi
  nh_info "unlock operator identity (passphrase prompt)"
  age -d -o "$out" "$NIXHOLD_IDENTITY_FILE"
}
