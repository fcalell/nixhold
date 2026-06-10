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

  local arch
  arch="$(nh_prompt_choose "Arch for $name:" \
    "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin")"

  # Profile list: framework-shipped + a free-text escape for
  # forker-authored profiles.
  local profile
  profile="$(nh_prompt_choose "Profile for $name:" \
    "nixhold.profiles.server" \
    "nixhold.profiles.workstationDarwin" \
    "nixhold.profiles.desktopLinux" \
    "(forker-authored — type custom name)")"

  if [ "$profile" = "(forker-authored — type custom name)" ]; then
    local custom
    custom="$(nh_prompt_input "Custom profile expression (Nix value)")"
    profile="$custom"
  fi

  local networks
  networks="$(nh_prompt_input "Networks (comma-separated)" "tailnet")"

  local public_ip="" public_fqdn=""
  if nh_prompt_confirm "Does $name have a stable public IP?"; then
    public_ip="$(nh_prompt_input "publicIp (e.g. 203.0.113.42)")"
    public_fqdn="$(nh_prompt_input "publicFqdn (optional, blank to skip)")"
  fi

  # Generate host SSH keypair into the per-host cache. The
  # pubkey goes into the fleet (committed); the privkey stays in
  # the cache (re-used for redeploys / install).
  local cache="$NIXHOLD_CACHE_DIR/host-keys/$name"
  mkdir -p "$cache"
  chmod 0700 "$cache"
  if [ ! -f "$cache/ssh_host_ed25519_key" ]; then
    ssh-keygen -t ed25519 -N "" -C "nixhold-host-$name" -f "$cache/ssh_host_ed25519_key" >/dev/null
    nh_ok "generated host SSH keypair at $cache"
  else
    nh_info "host SSH key already cached at $cache (reusing)"
  fi

  # Commit pubkey to the working-tree keys dir. (nh_layout evaluates
  # to a read-only store path; nh_worktree_keys_dir re-roots it under
  # the fleet, and falls back to <root>/keys when no host yet exists
  # to evaluate layout from — which is the case while adding the
  # first host.)
  local keys_dir
  keys_dir="$(nh_worktree_keys_dir)"
  mkdir -p "$keys_dir/hosts/$name"
  cp "$cache/ssh_host_ed25519_key.pub" "$keys_dir/hosts/$name/host.pub"
  nh_ok "committed host pubkey to $keys_dir/hosts/$name/host.pub"

  # Scaffold the host's module files so it evaluates now and builds
  # after `host install` fills in disko.nix + facter.json.
  local statever=""
  case "$arch" in
    *-linux) statever="$(nh_prompt_input "system.stateVersion (nixpkgs release)" "26.05")" ;;
  esac
  nh_scaffold_host_files "$root" "$name" "$arch" "$statever"

  # Append entry to hosts.nix.
  nh_append_host_entry "$hosts_file" "$name" "$arch" "$profile" "$networks" "$public_ip" "$public_fqdn"
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
  tmp="$(mktemp -t nixhold-hosts.XXXXXX)"
  entry="$entry" awk '
    /^}$/ && !done { print ENVIRON["entry"]; done=1 }
    { print }
  ' "$file" >"$tmp"
  mv "$tmp" "$file"
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
