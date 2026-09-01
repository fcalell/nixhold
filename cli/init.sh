# nixhold init — one-time per fork. Generates the operator's age
# identity, wraps it with a passphrase, drops it at
# $NIXHOLD_IDENTITY_FILE. Refuses to overwrite without --force.
#
# Recovery path: when run inside a fleet that already commits a
# wrapped identity (layout.ageIdentityWrapped), init offers to RESTORE
# that file instead of generating a new key — a new key would orphan
# every existing secret.

cmd_init() {
  local force=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --force) force=1; shift ;;
      -h | --help)
        cat <<'EOF'
Usage: nixhold init [--force]

Provisions the operator's age identity, passphrase-wrapped.
Stored at ${XDG_CONFIG_HOME:-~/.config}/nixhold/identity.age.txt.
Refuses to overwrite an existing identity unless --force is set.
EOF
        return 0
        ;;
      *) nh_err "unknown flag: $1"; return 1 ;;
    esac
  done

  nh_require_cmd age age-keygen gum

  if [ -f "$NIXHOLD_IDENTITY_FILE" ] && [ "$force" -ne 1 ]; then
    nh_err "identity already exists at $NIXHOLD_IDENTITY_FILE (use --force to overwrite)"
    return 1
  fi

  mkdir -p "$NIXHOLD_IDENTITY_DIR"
  chmod 0700 "$NIXHOLD_IDENTITY_DIR"

  # Restore-from-fleet: a committed wrapped identity means existing
  # secrets are encrypted to THAT key — restoring it is almost always
  # what the operator wants on a fresh machine. Full fleet-root
  # resolution (env → upward walk → baked default), so a checkout
  # subdirectory still finds it; quiet on failure — init legitimately
  # runs before any fleet exists.
  local committed=""
  if nh_fleet_root >/dev/null 2>&1; then
    committed="$(nh_worktree_layout_file ageIdentityWrapped 2>/dev/null || true)"
  fi
  if [ -n "$committed" ] && [ -f "$committed" ]; then
    nh_info "found committed operator identity: $committed"
    if nh_prompt_confirm "Restore it to $NIXHOLD_IDENTITY_FILE (recommended — generating a NEW key would orphan all existing secrets)?"; then
      cp "$committed" "$NIXHOLD_IDENTITY_FILE"
      chmod 0600 "$NIXHOLD_IDENTITY_FILE"
      nh_ok "restored operator identity to $NIXHOLD_IDENTITY_FILE (same passphrase as before)"
      return 0
    fi
    nh_warn "generating a NEW operator identity — existing secrets stay decryptable only by the OLD key"
  fi

  local tmp
  tmp="$(mktemp -t nixhold-identity.XXXXXX)"
  # Expand now: the trap fires at shell exit, after this function's
  # locals are gone.
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" EXIT

  age-keygen -o "$tmp" >/dev/null
  nh_info "wrapping identity with passphrase (you'll be prompted twice)"
  age -p -o "$NIXHOLD_IDENTITY_FILE" "$tmp"
  chmod 0600 "$NIXHOLD_IDENTITY_FILE"

  local pubkey
  pubkey="$(age-keygen -y "$tmp")"
  nh_ok "identity written to $NIXHOLD_IDENTITY_FILE"
  echo
  echo "Recipient (public) key — commit this into your fleet's keys/operator.pub:"
  echo "  $pubkey"
}
