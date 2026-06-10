# nixhold profile new <name>
# Scaffolds a profile under <layout.profilesDir>/.

cmd_profile_new() {
  local name="${1:-}"
  if [ -z "$name" ]; then
    nh_err "expected: nixhold profile new <name>"
    return 1
  fi
  # Worktree path, not nh_layout's read-only /nix/store view —
  # this verb writes.
  local profiles_dir; profiles_dir="$(nh_worktree_layout_dir profilesDir profiles)" || return 1
  mkdir -p "$profiles_dir"
  local target="$profiles_dir/$name.nix"
  if [ -f "$target" ]; then
    nh_err "$target already exists"
    return 1
  fi
  cat >"$target" <<EOF
{ inputs, lib, pkgs, ... }: {
  imports = [
    # inputs.nixhold.modules.services.openssh
    # inputs.nixhold.modules.services.tailscale
  ];

  # Set ${name} defaults here.
}
EOF
  nh_ok "scaffolded $target"
}
