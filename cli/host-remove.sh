# nixhold host remove [<name>] [--yes]
#
# Deletes the host entry from `hostsFile`, plus `hosts/<name>/` (the
# host's own modules and facter report), `secrets/<name>/` (the
# ciphertexts only that host declared) and `keys/hosts/<name>.pub`, and
# commits the removal.
#
# NOTHING is rekeyed. Every host reads the fleet's secrets with the one
# fleet key, so removing a host from the roster does not narrow any
# recipient set — and the machine still holds a copy of that key at
# /etc/nixhold/fleet.key. A machine that is being wiped takes the key
# with it; a machine that is being kept, sold or handed on is a reason
# to run `nixhold secret rotate` (new fleet key, everything
# re-encrypted, `nixhold deploy` puts it on the hosts that remain).
# That is the trade the one-fleet-key model makes, and the verb says so
# rather than pretending a shrink happened.
#
# `hosts/<name>/` goes too: a host that has left the roster has no
# module, and a successor is a new `host add`. The verb asks first
# (unless --yes), so a module worth keeping is copied out before.

cmd_host_remove() {
  local name="" yes=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --yes)
        yes=1
        shift
        ;;
      -h | --help)
        echo "Usage: nixhold host remove [<name>] [--yes]"
        return 0
        ;;
      -*)
        nh_err "unknown flag: $1"
        return 1
        ;;
      *)
        if [ -z "$name" ]; then
          name="$1"
          shift
        else
          nh_err "extra arg: $1"
          return 1
        fi
        ;;
    esac
  done

  local root
  root="$(nh_fleet_root)" || return 1

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
  local secrets_dir keys_dir hosts_dir
  secrets_dir="$(nh_worktree_secrets_dir)" || return 1
  keys_dir="$(nh_worktree_keys_dir)" || return 1
  hosts_dir="$(nh_worktree_hosts_dir)" || return 1

  nh_info "remove $name: its entry in hosts.nix, $hosts_dir/$name, $secrets_dir/$name, $keys_dir/hosts/$name.pub"
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
    local tmp
    tmp="$(mktemp -t nixhold-hosts-remove.XXXXXX)"
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

  if [ -d "$hosts_dir/$name" ]; then
    rm -rf "${hosts_dir:?}/$name"
    nh_ok "removed $hosts_dir/$name"
  fi
  if [ -d "$secrets_dir/$name" ]; then
    rm -rf "${secrets_dir:?}/$name"
    nh_ok "removed $secrets_dir/$name"
  fi
  if [ -e "$keys_dir/hosts/$name.pub" ]; then
    rm -f "$keys_dir/hosts/$name.pub"
    nh_ok "removed $keys_dir/hosts/$name.pub"
  fi

  nh_commit_paths "$root" "host($name): remove" \
    "$hosts_file" "$hosts_dir/$name" "$secrets_dir/$name" "$keys_dir/hosts/$name.pub"
  nh_warn "$name still holds the fleet key at /etc/nixhold/fleet.key — if that machine is not being wiped, run 'nixhold secret rotate' (new fleet key, every secret re-encrypted) and then 'nixhold deploy'"
}
