# Common helpers shared by every nixhold subcommand. Loaded once
# by the dispatcher; subcommands rely on the functions below.
# All output goes through nh_* helpers so colour + verbosity
# remain consistent.

nh_err() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; }
nh_warn() { printf '\033[33mwarn:\033[0m %s\n' "$*" >&2; }
nh_info() { printf '\033[36m·\033[0m %s\n' "$*" >&2; }
nh_ok() { printf '\033[32m✓\033[0m %s\n' "$*" >&2; }

# Locate the operator's fleet flake — the cwd unless overridden by
# $NIXHOLD_FLEET. Subcommands that scaffold files only refuse to
# run outside a flake, but `init` works without one (it provisions
# the operator-scoped identity, not fleet state).
nh_fleet_root() {
  local root="${NIXHOLD_FLEET:-$PWD}"
  if [ ! -f "$root/flake.nix" ]; then
    nh_err "no flake.nix at $root — pass NIXHOLD_FLEET=/path or cd into a fleet"
    return 1
  fi
  printf '%s' "$root"
}

# Evaluate an attr under the framework view of a host's config.
# Usage: nh_host_eval <host> <platform> <attrPath>
#   <platform>  = nixos | darwin
#   <attrPath>  = e.g. "nixhold.services" or "nixhold.fleet.derived.address"
# Returns JSON on stdout, exits non-zero on eval failure.
nh_host_eval() {
  local host="$1" platform="$2" path="$3"
  local root
  root="$(nh_fleet_root)" || return 1
  local set
  case "$platform" in
    nixos) set="nixosConfigurations" ;;
    darwin) set="darwinConfigurations" ;;
    *)
      nh_err "unknown platform: $platform"
      return 1
      ;;
  esac
  nix eval --json --no-warn-dirty "$root#$set.$host.config.$path"
}

# Read a layout path from the fleet without specifying a host —
# uses the first host's view, since `nixhold.layout` is set
# uniformly by mkFleet. Falls back to evaluating
# `<fleet>#self.outputs.lib.mkFleet` indirectly via any host.
nh_layout() {
  local key="$1"
  local root
  root="$(nh_fleet_root)" || return 1
  # Heuristic: pick the first nixos host, then the first darwin
  # host, then bail. The CLI usually runs from a fleet with at
  # least one host; before that, the operator hasn't reached the
  # subcommands that need layout (host add does its own probing).
  local first_host
  first_host="$(nix eval --json --no-warn-dirty \
    "$root#nixosConfigurations" --apply 'builtins.attrNames' 2>/dev/null \
    | jq -r 'first // empty')"
  if [ -z "$first_host" ]; then
    first_host="$(nix eval --json --no-warn-dirty \
      "$root#darwinConfigurations" --apply 'builtins.attrNames' 2>/dev/null \
      | jq -r 'first // empty')"
    if [ -z "$first_host" ]; then
      nh_err "fleet has no hosts yet — layout cannot be probed"
      return 1
    fi
    nh_host_eval "$first_host" darwin "nixhold.layout.$key"
  else
    nh_host_eval "$first_host" nixos "nixhold.layout.$key"
  fi
}

# Identity store: passphrase-wrapped operator age private key.
# `nixhold init` writes here; `secret edit` and the rest unwrap
# at edit-time only.
NIXHOLD_IDENTITY_DIR="${NIXHOLD_IDENTITY_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/nixhold}"
NIXHOLD_IDENTITY_FILE="${NIXHOLD_IDENTITY_FILE:-$NIXHOLD_IDENTITY_DIR/identity.age.txt}"
export NIXHOLD_IDENTITY_DIR NIXHOLD_IDENTITY_FILE

# Per-host private-key cache (host SSH key + host age identity).
# Survives `host remove` so the operator can recover. Honors a
# pre-set value (useful for tests / multiple isolated fleets).
NIXHOLD_CACHE_DIR="${NIXHOLD_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/nixhold}"
export NIXHOLD_CACHE_DIR

nh_require_cmd() {
  for c in "$@"; do
    if ! command -v "$c" >/dev/null 2>&1; then
      nh_err "missing required command: $c"
      return 1
    fi
  done
}
