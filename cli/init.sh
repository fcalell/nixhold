# nixhold init — one-time per fork. Generates the operator's age
# identity, wraps it with a passphrase, drops it at
# $NIXHOLD_IDENTITY_FILE. Refuses to overwrite without --force.

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

  nh_require_cmd age age-keygen

  if [ -f "$NIXHOLD_IDENTITY_FILE" ] && [ "$force" -ne 1 ]; then
    nh_err "identity already exists at $NIXHOLD_IDENTITY_FILE (use --force to overwrite)"
    return 1
  fi

  mkdir -p "$NIXHOLD_IDENTITY_DIR"
  chmod 0700 "$NIXHOLD_IDENTITY_DIR"

  local tmp
  tmp="$(mktemp -t nixhold-identity.XXXXXX)"
  trap 'rm -f "$tmp"' EXIT

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
