# Common helpers shared by every nixhold subcommand. Loaded once
# by the dispatcher; subcommands rely on the functions below.
# All output goes through nh_* helpers so colour + verbosity
# remain consistent.

nh_err() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; }
nh_warn() { printf '\033[33mwarn:\033[0m %s\n' "$*" >&2; }
nh_info() { printf '\033[36m·\033[0m %s\n' "$*" >&2; }
nh_ok() { printf '\033[32m✓\033[0m %s\n' "$*" >&2; }

# Locate the operator's fleet flake. Resolution order: $NIXHOLD_FLEET
# → nearest ancestor of $PWD holding a flake.nix (so a second worktree
# wins over the baked default while you stand in it) →
# $NIXHOLD_FLEET_DEFAULT, which programs.nixhold bakes into the
# wrapped CLI. Subcommands that scaffold files refuse to run outside a
# fleet, but `init` works without one (it provisions the
# operator-scoped identity, not fleet state).
#
# Contract: only the path reaches stdout — every caller consumes this
# through command substitution — so prompts and diagnostics go to
# stderr.
_NH_FLEET_ROOT="${_NH_FLEET_ROOT:-}"

nh_fleet_root() {
  # Memo: command-substitution callers each run in their own subshell,
  # so this mainly keeps one verb from walking (or prompting) twice.
  if [ -n "$_NH_FLEET_ROOT" ]; then
    printf '%s' "$_NH_FLEET_ROOT"
    return 0
  fi

  if [ -n "${NIXHOLD_FLEET:-}" ]; then
    if [ ! -f "$NIXHOLD_FLEET/flake.nix" ]; then
      nh_err "no flake.nix at $NIXHOLD_FLEET (from \$NIXHOLD_FLEET)"
      return 1
    fi
    _NH_FLEET_ROOT="$NIXHOLD_FLEET"
    printf '%s' "$_NH_FLEET_ROOT"
    return 0
  fi

  local dir="$PWD"
  while :; do
    if [ -f "$dir/flake.nix" ]; then
      _NH_FLEET_ROOT="$dir"
      printf '%s' "$_NH_FLEET_ROOT"
      return 0
    fi
    [ "$dir" = "/" ] && break
    dir="${dir%/*}"
    [ -z "$dir" ] && dir="/"
  done

  local fallback="${NIXHOLD_FLEET_DEFAULT:-}"
  if [ -n "$fallback" ]; then
    # The module bakes the option string verbatim, so a leading $HOME
    # arrives unexpanded; expand it without eval.
    # shellcheck disable=SC2016 # the patterns are literal '$HOME' text
    case "$fallback" in
      '$HOME') fallback="$HOME" ;;
      '$HOME/'*) fallback="$HOME/${fallback#\$HOME/}" ;;
    esac
    if [ -f "$fallback/flake.nix" ]; then
      _NH_FLEET_ROOT="$fallback"
      printf '%s' "$_NH_FLEET_ROOT"
      return 0
    fi
    if [ -d "$fallback" ]; then
      nh_err "$fallback (from \$NIXHOLD_FLEET_DEFAULT) exists but holds no flake.nix"
      return 1
    fi
    nh_clone_fleet "$fallback" || return 1
    _NH_FLEET_ROOT="$fallback"
    printf '%s' "$_NH_FLEET_ROOT"
    return 0
  fi

  nh_err "no fleet found — cd into a checkout (flake.nix here or above), set NIXHOLD_FLEET=/path, or enable programs.nixhold so the default checkout is baked in"
  return 1
}

# nh_clone_fleet <dir> — the fresh-machine path: the baked default
# checkout doesn't exist yet (first login after an ISO install), so
# offer to clone $NIXHOLD_REPO_URL ("owner/repo", github.com assumed)
# there. Cloned over the operator's normal SSH credentials — the repo
# deploy key is ISO-only. Interactive by construction: no TTY means no
# offer.
nh_clone_fleet() {
  local dir="$1" repo="${NIXHOLD_REPO_URL:-}" remote reply=""
  if [ -z "$repo" ]; then
    nh_err "no fleet at $dir and no repo baked in (set layout.repoUrl) — clone your fleet there or set NIXHOLD_FLEET"
    return 1
  fi
  remote="git@github.com:${repo%.git}.git"
  if [ ! -t 2 ]; then
    nh_err "no fleet at $dir — clone $remote there (not offering: no terminal)"
    return 1
  fi
  nh_require_cmd git || return 1

  nh_info "no fleet checkout at $dir"
  if command -v gum >/dev/null 2>&1 && [ -t 0 ]; then
    if gum confirm "Clone $remote into $dir?"; then reply=y; fi
  else
    printf 'Clone %s into %s? [y/N] ' "$remote" "$dir" >&2
    read -r reply </dev/tty || reply=""
  fi
  case "$reply" in
    y | Y | yes | Yes) ;;
    *)
      nh_err "declined — clone $remote to $dir, or run from a fleet checkout"
      return 1
      ;;
  esac

  mkdir -p "${dir%/*}" 2>/dev/null || true
  if ! git clone "$remote" "$dir" >&2; then
    nh_err "clone of $remote failed — check your SSH access to github.com"
    return 1
  fi
  if [ ! -f "$dir/flake.nix" ]; then
    nh_err "cloned $remote to $dir but it holds no flake.nix"
    return 1
  fi
  nh_ok "cloned fleet to $dir"
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
