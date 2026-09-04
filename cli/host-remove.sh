# nixhold host remove [<name>] [--yes]
# Deletes the host entry from `hostsFile`, plus `secrets/hosts/<name>/`
# and `keys/hosts/<name>/`, and commits the removal. Does NOT touch
# `hosts/<name>/` (the operator's module may be kept for a successor)
# or `~/.cache/nixhold/host-keys/<name>/` — the operator removes those
# manually if they want a clean break.

cmd_host_remove() {
  local name="" yes=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --yes) yes=1; shift ;;
      -h | --help) echo "Usage: nixhold host remove [<name>] [--yes]"; return 0 ;;
      -*) nh_err "unknown flag: $1"; return 1 ;;
      *) if [ -z "$name" ]; then name="$1"; shift; else nh_err "extra arg: $1"; return 1; fi ;;
    esac
  done

  local root; root="$(nh_fleet_root)" || return 1

  if [ -z "$name" ]; then
    if ! nh_tty; then
      nh_err "expected: nixhold host remove <name>"
      return 1
    fi
    name="$(nh_pick_host "Remove which host from the fleet?")" || return 1
  fi

  # Resolve worktree paths BEFORE rewriting hosts.nix — the layout
  # probe evals the fleet, and the worktree helpers (not raw
  # nh_layout) are required because layout.* eval to read-only
  # /nix/store source paths.
  local secrets_dir keys_dir
  secrets_dir="$(nh_worktree_secrets_dir)" || return 1
  keys_dir="$(nh_worktree_keys_dir)" || return 1

  nh_info "remove $name: its entry in hosts.nix, $secrets_dir/hosts/$name, $keys_dir/hosts/$name"
  if [ "$yes" -ne 1 ] && ! nh_prompt_confirm "Remove $name from the fleet?"; then
    nh_info "aborted"
    return 0
  fi

  # Strip the host's attrset entry from hosts.nix. Conservative
  # range-delete from `^[[:space:]]+<name>[[:space:]]*=[[:space:]]*{`
  # through the matching closing `};` at the SAME indentation as the
  # opening line, so nested `{ ... };` blocks inside the entry don't
  # terminate the range early.
  local hosts_file="$root/hosts.nix"
  if [ -f "$hosts_file" ]; then
    local tmp; tmp="$(mktemp -t nixhold-hosts-remove.XXXXXX)"
    awk -v name="$name" '
      BEGIN { skip = 0 }
      {
        if (!skip && $0 ~ ("^[[:space:]]+" name "[[:space:]]*=[[:space:]]*\\{")) {
          skip = 1
          indent = $0
          sub(/[^ \t].*$/, "", indent)
          close_re = "^" indent "\\};[[:space:]]*$"
          next
        }
        if (skip && $0 ~ close_re) {
          skip = 0; next
        }
        if (!skip) print
      }
    ' "$hosts_file" >"$tmp"
    mv "$tmp" "$hosts_file"
    nh_ok "removed entry from $hosts_file"
    nh_fleet_view_reset
  fi

  if [ -d "$secrets_dir/hosts/$name" ]; then
    rm -rf "$secrets_dir/hosts/$name"
    nh_ok "removed $secrets_dir/hosts/$name"
  fi
  if [ -d "$keys_dir/hosts/$name" ]; then
    rm -rf "$keys_dir/hosts/$name"
    nh_ok "removed $keys_dir/hosts/$name"
  fi
  nh_commit_paths "$root" "host($name): remove" \
    "$hosts_file" "$secrets_dir/hosts/$name" "$keys_dir/hosts/$name"
  nh_info "next: remove hosts/$name if you keep no module for it"
}
