# nixhold host add [<name>] [--install <user>@<ip>]
#
# The walk that brings a host into the fleet:
#   1. Prompt name (when not given), arch, profile, networks,
#      publicIp/publicFqdn, stateVersion — every abort happens here,
#      before the first write.
#   2. Generate a host SSH keypair into the per-host cache; commit its
#      pubkey + escrow under `nixhold.layout.keysDir` (a fleet with no
#      operator identity yet gets one here).
#   3. Scaffold <hostsDir>/<name>/default.nix and append the entry to
#      `hostsFile`.
#   4. Provision every declared-but-missing secret.
#   5. Ask "install now?": this machine (on the ISO, or a Mac), over
#      ssh to an address, or later. --install <addr> answers it.
# What this verb wrote is committed before the install starts; on the
# installer ISO, whose checkout is ephemeral, it is pushed too.

cmd_host_add() {
  local name="" install_target=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --install) install_target="$2"; shift 2 ;;
      -h | --help)
        cat <<'EOF'
Usage: nixhold host add [<name>] [--install <user>@<ip>]

  Walks the host into the fleet, then asks whether to install it now.
  --install <user>@<ip> answers that with "over ssh to <ip>".
EOF
        return 0
        ;;
      -*) nh_err "unknown flag: $1"; return 1 ;;
      *) if [ -z "$name" ]; then name="$1"; shift; else nh_err "extra arg: $1"; return 1; fi ;;
    esac
  done
  if [ -z "$name" ] && ! nh_tty; then
    nh_err "expected: nixhold host add <name>"
    return 1
  fi

  nh_require_cmd gum jq nix ssh-keygen
  local root
  root="$(nh_fleet_root)" || return 1

  if [ -z "$name" ]; then
    name="$(nh_prompt_input "Name for the new host")" || name=""
    case "$name" in
      "" ) nh_err "aborted — no name given; nothing was written"; return 1 ;;
      *[!A-Za-z0-9_-]*) nh_err "host names are [A-Za-z0-9_-]: '$name'"; return 1 ;;
    esac
  fi

  # Refuse up front, before generating keys or scaffolding files —
  # failing at the hosts.nix append would leave half the work done.
  # (The layout probes fall back to the defaults while the fleet has
  # no host to read them from — the first `host add`.)
  local hosts_file hosts_dir
  hosts_file="$(nh_worktree_layout_file hostsFile 2>/dev/null)" || hosts_file="$root/hosts.nix"
  hosts_dir="$(nh_worktree_layout_dir hostsDir hosts)" || return 2
  if [ -f "$hosts_file" ] && grep -qE "^[[:space:]]+${name}[[:space:]]*=[[:space:]]*\{" "$hosts_file"; then
    nh_err "host '$name' already present in $hosts_file (run 'host remove' first; 'host rotate-key' regenerates its key)"
    return 1
  fi

  # Every prompt is checked and every abort happens HERE, before the
  # first write: this verb may run inside `host install`'s picker,
  # where errexit is off, and a cancelled (Esc) gum prompt returns an
  # empty string. Unchecked, that wrote `arch = ""; profile = ;` into
  # hosts.nix and minted a keypair + escrow for a half-added host.
  local arch
  arch="$(nh_prompt_choose "Arch for $name:" \
    "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin")" || arch=""
  if [ -z "$arch" ]; then
    nh_err "aborted — no arch chosen; nothing was written"
    return 1
  fi

  # Profile list: framework-shipped + a free-text escape for
  # forker-authored profiles.
  local profile
  profile="$(nh_prompt_choose "Profile for $name:" \
    "nixhold.profiles.server" \
    "nixhold.profiles.workstationDarwin" \
    "nixhold.profiles.desktopLinux" \
    "(forker-authored — type custom name)")" || profile=""
  if [ -z "$profile" ]; then
    nh_err "aborted — no profile chosen; nothing was written"
    return 1
  fi

  if [ "$profile" = "(forker-authored — type custom name)" ]; then
    local custom
    custom="$(nh_prompt_input "Custom profile expression (Nix value)")" || custom=""
    if [ -z "$custom" ]; then
      nh_err "aborted — no profile expression given; nothing was written"
      return 1
    fi
    profile="$custom"
  fi

  local networks
  networks="$(nh_prompt_input "Networks (comma-separated)" "tailnet")" || networks=""
  if [ -z "$networks" ]; then
    nh_err "aborted — no networks given; nothing was written"
    return 1
  fi

  local public_ip="" public_fqdn=""
  if nh_prompt_confirm "Does $name have a stable public IP?"; then
    public_ip="$(nh_prompt_input "publicIp (e.g. 203.0.113.42)")" || public_ip=""
    if [ -z "$public_ip" ]; then
      nh_err "aborted — no publicIp given; nothing was written"
      return 1
    fi
    public_fqdn="$(nh_prompt_input "publicFqdn (optional, blank to skip)")" || public_fqdn=""
  fi

  # stateVersion belongs with the other prompts: asking it after the
  # keypair exists would put a cancel on the far side of a write.
  local statever=""
  case "$arch" in
    *-linux)
      statever="$(nh_prompt_input "system.stateVersion (nixpkgs release)" "26.05")" || statever=""
      ;;
    *-darwin)
      statever="$(nh_prompt_input "system.stateVersion (nix-darwin integer)" "6")" || statever=""
      ;;
  esac
  if [ -z "$statever" ]; then
    nh_err "aborted — no stateVersion given; nothing was written"
    return 1
  fi

  # Generate host SSH keypair into the per-host cache. The
  # pubkey goes into the fleet (committed); the privkey stays in
  # the cache (re-used for redeploys / install).
  local cache="$NIXHOLD_CACHE_DIR/host-keys/$name"
  if ! mkdir -p "$cache" || ! chmod 0700 "$cache"; then
    nh_err "could not create the host-key cache at $cache"
    return 1
  fi
  if [ ! -f "$cache/ssh_host_ed25519_key" ]; then
    ssh-keygen -t ed25519 -N "" -C "nixhold-host-$name" -f "$cache/ssh_host_ed25519_key" >/dev/null || {
      nh_err "could not generate a host SSH keypair at $cache"
      return 1
    }
    nh_ok "generated host SSH keypair at $cache"
  else
    nh_info "host SSH key already cached at $cache (reusing)"
  fi

  # Commit the pubkey (the host's age recipient) AND escrow the private
  # half beside it, in one call from one private key — so the host is
  # re-imageable from repo + passphrase alone from birth and the pair
  # can never disagree. (nh_layout evaluates to a read-only store path;
  # nh_worktree_keys_dir re-roots it under the fleet, and falls back to
  # <root>/keys when no host yet exists to evaluate layout from — which
  # is the case while adding the first host.) A fleet with no operator
  # pubkey yet gets a warning rather than a half-added host; lint flags
  # the missing escrow.
  local keys_dir
  keys_dir="$(nh_worktree_keys_dir)" || return 2
  nh_escrow_host_key "$name" "$cache/ssh_host_ed25519_key" || {
    nh_err "host key for $name is NOT escrowed — nothing else was written"
    return 1
  }

  # Scaffold the host's module so it evaluates now; `host install`
  # completes it with the disk (roster) and the facter report.
  nh_scaffold_host_files "$hosts_dir" "$name" "$arch" "$statever" || return 1

  # Append entry to hosts.nix. The module path is relative to the
  # roster file, wherever the layout puts either.
  local modpath
  modpath="$(realpath -m --relative-to="$(dirname "$hosts_file")" "$hosts_dir/$name/default.nix")"
  case "$modpath" in
    /* | ../*) ;;
    *) modpath="./$modpath" ;;
  esac
  nh_append_host_entry "$hosts_file" "$name" "$arch" "$profile" "$networks" "$public_ip" "$public_fqdn" "$modpath" || return 1
  nh_ok "wrote host entry for $name into $hosts_file"
  nh_fleet_view_reset

  # Make the generated files visible to git-flake eval: a dirty git
  # flake includes modified tracked files but NOT untracked ones, so
  # without this every following eval (secret bootstrap, lint,
  # --install) sees a hosts.nix entry whose ./hosts/<name> files
  # "don't exist" — and, worse, the recipients computation silently
  # omits the invisible host.pub.
  nh_stage_for_eval "$root" "$keys_dir/hosts/$name" "$hosts_dir/$name" "$hosts_file"

  # The roster entry, the scaffold, the host key pair and (on a first
  # host) the operator identity: committed now, before the secrets
  # walk that may open editors or fail.
  nh_commit_paths "$root" "host $name: add" \
    "$hosts_file" "$hosts_dir/$name" "$keys_dir/hosts/$name" \
    "$keys_dir/operator.pub" "$keys_dir/operator.age"

  # Provision any declared-but-missing secrets (each ciphertext is
  # committed by the walk). Best-effort — the host's own module may
  # not be evaluable yet (the operator hasn't written it), so a
  # failure here is a warning.
  . "$NIXHOLD_LIB_ROOT/secret-edit.sh"
  nh_provision_missing_secrets "$name" || nh_warn "secret provisioning skipped (host not evaluable yet)"

  # The installer's checkout is ephemeral: push before an install that
  # may take a while or fail.
  nh_push_if_installer "$root"
  nh_ok "$name is in the fleet"

  nh_add_install_question "$name" "$arch" "$install_target"
}

# nh_add_install_question <name> <arch> [addr] — the walk's last step:
# install now, or say how to later. The choices are the install entry
# points that exist from HERE: in place on the ISO (NixOS) or on this
# Mac (darwin), over ssh to a booted installer, or not yet.
nh_add_install_question() {
  local name="$1" arch="$2" addr="${3:-}" root choice
  root="$(nh_fleet_root)" || return 1
  . "$NIXHOLD_LIB_ROOT/host-install.sh"
  if [ -n "$addr" ]; then
    cmd_host_install "$name" --remote "$addr"
    return $?
  fi
  local later
  case "$arch" in
    *-darwin) later="nixhold host install $name  (on the Mac itself)" ;;
    *) later="nixhold host install $name --remote root@<ip>  (a target booted from the fleet ISO or any installer)" ;;
  esac
  if ! nh_tty; then
    nh_info "next: $later"
    return 0
  fi
  local options=()
  case "$arch" in
    *-darwin)
      [ "$(uname -s)" = "Darwin" ] && options+=("this Mac, now")
      ;;
    *)
      nh_installer_env && options+=("this machine, now (erases its disk)")
      options+=("over ssh to a booted installer")
      ;;
  esac
  options+=("later")
  choice="$(gum choose --header "Install $name?" "${options[@]}")" || choice="later"
  case "$choice" in
    "this Mac, now" | "this machine, now"*)
      cmd_host_install "$name"
      ;;
    "over ssh"*)
      addr="$(nh_prompt_input "Installer address (root@<ip>)")" || addr=""
      if [ -z "$addr" ]; then
        nh_info "no address — install later with: $later"
        return 0
      fi
      cmd_host_install "$name" --remote "$addr"
      ;;
    *)
      nh_info "next: $later"
      ;;
  esac
}

# Append a host entry just before the closing brace of the hosts.nix
# attrset. Idempotent — if `<name> = {` already exists, refuses
# (the operator should run `host remove` first).
nh_append_host_entry() {
  local file="$1" name="$2" arch="$3" profile="$4" networks_csv="$5" pip="$6" pfqdn="$7" modpath="$8"

  if [ ! -f "$file" ]; then
    cat >"$file" <<'EOF'
{ nixhold, ... }:
{
}
EOF
  fi

  if grep -qE "^[[:space:]]+${name}[[:space:]]*=[[:space:]]*\{" "$file"; then
    nh_err "host '$name' already present in $file (run 'host remove' first)"
    return 1
  fi

  local networks_nix
  networks_nix="$(printf '%s\n' "$networks_csv" \
    | awk -F, '{ for (i=1;i<=NF;i++) { gsub(/^ +| +$/, "", $i); printf "\"%s\" ", $i } }')"

  local entry
  entry="  ${name} = {
    arch = \"${arch}\";
    profile = ${profile};
    modules = [ ${modpath} ];
    networks = [ ${networks_nix}];"
  if [ -n "$pip" ]; then
    entry="${entry}
    publicIp = \"${pip}\";"
  fi
  if [ -n "$pfqdn" ]; then
    entry="${entry}
    publicFqdn = \"${pfqdn}\";"
  fi
  entry="${entry}
  };
"

  # Splice before the last '}' line. The entry goes in via ENVIRON,
  # not `awk -v` — `-v` processes backslash escapes, which would
  # mangle a custom profile expression containing `\`.
  local tmp
  tmp="$(mktemp -t nixhold-hosts.XXXXXX)" || {
    nh_err "could not create a temp file to rewrite $file"
    return 1
  }
  if ! entry="$entry" awk '
    /^}$/ && !done { print ENVIRON["entry"]; done=1 }
    { print }
  ' "$file" >"$tmp" || ! mv "$tmp" "$file"; then
    rm -f "$tmp"
    nh_err "could not write the host entry into $file"
    return 1
  fi
}

# Scaffold a freshly-added host's module: the stateVersion line alone.
# Hostname, platform, disko and the facter pointer are all
# framework-set, so nothing else is the operator's to write yet.
nh_scaffold_host_files() {
  local hosts_dir="$1" name="$2" arch="$3" statever="$4"
  local dir="$hosts_dir/$name"
  mkdir -p "$dir"

  if [ -e "$dir/default.nix" ]; then
    nh_info "$dir/default.nix exists — leaving it untouched"
    return 0
  fi

  case "$arch" in
    *-darwin)
      cat >"$dir/default.nix" <<EOF
{ ... }:
{
  system.stateVersion = $statever;
}
EOF
      ;;
    *)
      cat >"$dir/default.nix" <<EOF
{ ... }:
{
  system.stateVersion = "$statever";
}
EOF
      ;;
  esac
  nh_ok "scaffolded $dir/default.nix"
}
