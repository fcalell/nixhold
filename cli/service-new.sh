# nixhold service new <name>
# Scaffolds a service module under <layout.modulesDir>/services/.

cmd_service_new() {
  local name="$1"
  if [ -z "$name" ]; then
    nh_err "expected: nixhold service new <name>"
    return 1
  fi
  local modules_dir; modules_dir="$(nh_layout modulesDir | jq -r '.')"
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
}
