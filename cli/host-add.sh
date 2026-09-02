# nixhold host add <name> [--install <user>@<ip>]
#
# Interactive gum-driven flow:
#   1. Prompt arch (enum picker).
#   2. Prompt profile (from `inputs.nixhold.profiles.*` + the
#      operator's own profilesDir).
#   3. Prompt network membership.
#   4. Optionally prompt publicIp/publicFqdn.
#   5. Generate a host SSH keypair into the per-host cache.
#   6. Commit the host pubkey under `nixhold.layout.keysDir`.
#   7. Append the host entry into `nixhold.layout.hostsFile`.
#   8. If --install was passed, chain to `nixhold host install`.

cmd_host_add() {
  local name="" install_target=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --install) install_target="$2"; shift 2 ;;
      -h | --help)
        cat <<'EOF'
Usage: nixhold host add <name> [--install <user>@<ip>]
EOF
        return 0
        ;;
      -*) nh_err "unknown flag: $1"; return 1 ;;
      *) if [ -z "$name" ]; then name="$1"; shift; else nh_err "extra arg: $1"; return 1; fi ;;
    esac
  done
  if [ -z "$name" ]; then
    nh_err "expected: nixhold host add <name>"
    return 1
  fi

  nh_require_cmd gum jq nix ssh-keygen
  local root
  root="$(nh_fleet_root)" || return 1

  # Refuse up front, before generating keys or scaffolding files —
  # failing at the hosts.nix append would leave half the work done.
  local hosts_file="$root/hosts.nix"
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
      if [ -z "$statever" ]; then
        nh_err "aborted — no stateVersion given; nothing was written"
        return 1
      fi
      ;;
  esac

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
  nh_escrow_host_key "$name" "$cache/ssh_host_ed25519_key" ||
    nh_warn "host key for $name is NOT escrowed — run 'nixhold init' then 'nixhold host rotate-key $name'"

  # Scaffold the host's module files so it evaluates now and builds
  # after `host install` fills in disko.nix + facter.json.
  nh_scaffold_host_files "$root" "$name" "$arch" "$statever" || return 1

  # Append entry to hosts.nix.
  nh_append_host_entry "$hosts_file" "$name" "$arch" "$profile" "$networks" "$public_ip" "$public_fqdn" || return 1
  nh_ok "wrote host entry for $name into $hosts_file"

  # Make the generated files visible to git-flake eval: a dirty git
  # flake includes modified tracked files but NOT untracked ones, so
  # without this every following eval (secret bootstrap, lint,
  # --install) sees a hosts.nix entry whose ./hosts/<name> files
  # "don't exist" — and, worse, the recipients computation silently
  # omits the invisible host.pub.
  if git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$root" add --intent-to-add \
      "$keys_dir/hosts/$name" "$root/hosts/$name" "$hosts_file" 2>/dev/null ||
      nh_warn "git add of generated files failed — run 'git add keys/ hosts/ hosts.nix' before evaluating"
  else
    nh_warn "fleet is not a git worktree — if it becomes one, 'git add' the generated files before evaluating"
  fi

  # Final scaffolding step: provision any declared-but-missing secrets.
  # Best-effort — the host's own module may not be evaluable yet (the
  # operator hasn't written it), so a failure here is a warning.
  . "$NIXHOLD_LIB_ROOT/secret-bootstrap.sh"
  cmd_secret_bootstrap "$name" || nh_warn "secret bootstrap skipped (host not evaluable yet)"

  if [ -n "$install_target" ]; then
    . "$NIXHOLD_LIB_ROOT/host-install.sh"
    cmd_host_install "$name" --remote "$install_target"
  fi
}

# Append a host entry just before the closing brace of the hosts.nix
# attrset. Idempotent — if `<name> = {` already exists, refuses
# (the operator should run `host remove` first).
nh_append_host_entry() {
  local file="$1" name="$2" arch="$3" profile="$4" networks_csv="$5" pip="$6" pfqdn="$7"

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
    modules = [ ./hosts/${name}/default.nix ];
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

# Scaffold a freshly-added host's module files so it evaluates now
# (greppable/lintable) and builds after `host install` writes the real
# disko.nix + facter.json. NixOS hosts import disko + the facter
# pointer and get a placeholder disko.nix install overwrites; darwin
# hosts get a minimal default.nix.
nh_scaffold_host_files() {
  local root="$1" name="$2" arch="$3" statever="$4"
  local dir="$root/hosts/$name"
  mkdir -p "$dir"

  if [ -e "$dir/default.nix" ]; then
    nh_info "hosts/$name/default.nix exists — leaving it untouched"
    return 0
  fi

  case "$arch" in
    *-darwin)
      cat >"$dir/default.nix" <<EOF
{ ... }:
{
  networking.hostName = "$name";

  # nix-darwin's stateVersion is an integer; check the nix-darwin
  # changelog before bumping.
  system.stateVersion = 6;

  # nixhold.home.extraModules = [ ../../home/$name ];
}
EOF
      nh_ok "scaffolded hosts/$name/default.nix"
      ;;
    *)
      cat >"$dir/default.nix" <<EOF
{ inputs, ... }:
{
  imports = [
    inputs.nixhold.inputs.disko.nixosModules.disko
    ./disko.nix
  ];

  networking.hostName = "$name";

  # Hardware report written by \`nixhold host install\`. Until it
  # exists the host evaluates but a build is blocked by the facter
  # guard.
  nixhold.hardware.facterReport = ./facter.json;

  system.stateVersion = "$statever";

  # nixhold.home.extraModules = [ ../../home/$name ];
}
EOF
      if [ ! -e "$dir/disko.nix" ]; then
        cat >"$dir/disko.nix" <<'EOF'
# PLACEHOLDER — `nixhold host install` overwrites this with a layout
# generated from the target's real disk. It evaluates so the host is
# greppable/lintable pre-install; a build stays blocked by the facter
# guard until install runs.
{
  disko.devices.disk.main = {
    type = "disk";
    device = "/dev/disk/by-id/REPLACE-ME";
    content = {
      type = "gpt";
      partitions = {
        ESP = {
          size = "512M";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
          };
        };
        root = {
          size = "100%";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
          };
        };
      };
    };
  };
}
EOF
        nh_ok "scaffolded hosts/$name/{default.nix,disko.nix} (placeholder disk)"
      else
        nh_ok "scaffolded hosts/$name/default.nix"
      fi
      ;;
  esac
}
