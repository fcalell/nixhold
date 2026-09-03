# nixhold service new <name>
# Scaffolds a service module under <layout.modulesDir>/services/ and
# stages it, so the eval that follows the operator's edit sees it. It
# is not committed: the scaffold is a starting point, and what the
# operator writes into it is theirs.

cmd_service_new() {
  local name="${1:-}"
  case "$name" in
    -h | --help) echo "Usage: nixhold service new <name>"; return 0 ;;
    "") nh_err "expected: nixhold service new <name>"; return 1 ;;
    *[!a-z0-9-]*) nh_err "service names are kebab-case ([a-z0-9-]): '$name'"; return 1 ;;
  esac
  # Worktree path, not nh_layout's read-only /nix/store view —
  # this verb writes.
  local modules_dir; modules_dir="$(nh_worktree_layout_dir modulesDir modules)" || return 1
  mkdir -p "$modules_dir/services"
  local target="$modules_dir/services/$name.nix"
  if [ -f "$target" ]; then
    nh_err "$target already exists"
    return 1
  fi
  cat >"$target" <<EOF
{ config, lib, ... }:
let
  cfg = config.nixhold.services.${name};
  types' = config.nixhold.types;
in {
  options.nixhold.services.${name} = {
    enable = lib.mkEnableOption "${name}";
    network = lib.mkOption { type = types'.network; default = {}; };
    expose  = lib.mkOption { type = types'.expose;  default = {}; };
  };

  config = lib.mkIf cfg.enable {
    # services.${name} = { ... };
  };
}
EOF
  nh_ok "scaffolded $target"
  local root
  root="$(nh_fleet_root)" || return 0
  nh_stage_for_eval "$root" "$target"
}
