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
# there. Runs through nh_repo_git: the installer image clones over the
# repo deploy key it bakes, a fleet machine over the operator's own
# credentials. Interactive by construction: no TTY means no offer.
_NH_CLONING=0
nh_clone_fleet() {
  local dir="$1" repo="${NIXHOLD_REPO_URL:-}" remote reply=""
  # Unwrapping the deploy key can walk back through nh_fleet_root (the
  # identity may live in the fleet), which would land here again on a
  # machine that has no checkout yet. One attempt per process.
  if [ "$_NH_CLONING" = "1" ]; then
    nh_err "no fleet checkout at $dir (already trying to clone one — the operator identity is not reachable without it)"
    return 1
  fi
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
  _NH_CLONING=1
  if ! nh_repo_git clone "$remote" "$dir" >&2; then
    _NH_CLONING=0
    nh_err "clone of $remote failed — check the fleet repo credentials (deploy key on the installer, your own SSH key otherwise)"
    return 1
  fi
  _NH_CLONING=0
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

# ---------------------------------------------------------------------
# Process-scoped scratch space + exit handlers.
#
# Key material (host keys, the repo deploy key, the unwrapped operator
# identity) is staged under ONE 0700 directory keyed on the CLI's pid,
# wiped by a single EXIT handler installed by the dispatcher. Deriving
# the root from $$ rather than a shell variable is what makes it usable
# from command substitution: `d="$(nh_tmpdir …)"` runs in a subshell,
# where an appended array — or a trap — would be thrown away.

nh_tmp_root() {
  local root="${TMPDIR:-/tmp}/nixhold-$$"
  # Plain `mkdir`, not `mkdir -p`: the parent always exists, and -p
  # would happily adopt whatever already sits at $root — a symlink, or
  # another user's directory. A failing mkdir is therefore either the
  # normal same-process re-entry (the root is there and it is OURS: a
  # real directory, owned by this uid) or an entry we must refuse.
  if ! mkdir "$root" 2>/dev/null; then
    if [ -L "$root" ] || [ ! -d "$root" ] || [ ! -O "$root" ]; then
      nh_err "cannot stage key material in $root — either ${TMPDIR:-/tmp} is not writable, or something already sits at that path that is not a directory of ours (remove it, or point \$TMPDIR elsewhere)"
      return 1
    fi
  fi
  chmod 700 "$root" || return 1
  printf '%s' "$root"
}

# nh_tmpdir [label] — a private 0700 scratch dir, removed when the CLI
# exits. Replaces bare `mktemp -d` + a per-caller EXIT trap, which
# clobbered whatever trap the caller before it had installed.
nh_tmpdir() {
  local label="${1:-tmp}" root d
  root="$(nh_tmp_root)" || {
    nh_err "could not create the scratch directory under ${TMPDIR:-/tmp}"
    return 1
  }
  d="$(mktemp -d "$root/$label.XXXXXX")" || {
    nh_err "could not create a scratch directory under $root"
    return 1
  }
  chmod 700 "$d" || {
    rm -rf "$d"
    nh_err "could not restrict $d"
    return 1
  }
  printf '%s' "$d"
}

# nh_at_exit <function-name> — register a handler the dispatcher's
# single EXIT/INT/TERM trap runs. Verbs that mutate the fleet in
# several steps register their rollback here instead of installing a
# trap of their own (which would drop the scratch wipe, and each
# other's).
_NH_EXIT_HANDLERS=""
nh_at_exit() {
  _NH_EXIT_HANDLERS="${_NH_EXIT_HANDLERS}${_NH_EXIT_HANDLERS:+ }$1"
}

_NH_EXIT_RAN=0
nh_run_at_exit() {
  [ "$_NH_EXIT_RAN" -eq 0 ] || return 0
  _NH_EXIT_RAN=1
  local f
  for f in $_NH_EXIT_HANDLERS; do
    "$f" || true
  done
  local root="${TMPDIR:-/tmp}/nixhold-$$"
  [ -d "$root" ] && rm -rf "$root"
  return 0
}

# nh_installer_env — true inside the fleet installer ISO. The marker
# file is a fixed contract between the ISO module and the CLI; it lives
# here (not in host-install) because the clone/deploy-key paths need it
# before any verb is sourced. ($NIXHOLD_INSTALLER_MARKER overrides the
# path — test hook only, never set in production.)
nh_installer_env() {
  [ -f "${NIXHOLD_INSTALLER_MARKER:-/etc/nixhold-installer}" ]
}

# nh_sudo <cmd…> — the installer ISO runs as root; anywhere else the
# few phases that touch /etc, /mnt and /dev escalate.
nh_sudo() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

# nh_repo_deploy_key — plaintext path of the fleet repo's deploy key,
# or nothing.
#
#   0 + path   a deploy key is in hand (installer environment)
#   1          none configured — use the operator's own credentials
#   2          one is configured but unusable (reported)
#
# The installer image bakes keys/repo.key.age and points
# $NIXHOLD_REPO_KEY_FILE at it; the operator passphrase is what turns
# it into a usable key, so the decrypt happens once per CLI process
# into the scratch root (tmpfs on the ISO) and is wiped on exit. Off
# the ISO nothing is configured and git runs on the operator's own SSH
# credentials — a fleet machine has them already.
nh_repo_deploy_key() {
  local src="${NIXHOLD_REPO_KEY_FILE:-}" root out
  if [ -z "$src" ] && nh_installer_env; then
    src="/etc/nixhold/keys/repo.key.age"
    [ -f "$src" ] || src=""
  fi
  [ -n "$src" ] || return 1
  if [ ! -f "$src" ]; then
    nh_err "no repo deploy key at $src (from \$NIXHOLD_REPO_KEY_FILE) — the installer image is incomplete"
    return 2
  fi
  root="$(nh_tmp_root)" || {
    nh_err "could not create the scratch directory for the repo deploy key"
    return 2
  }
  out="$root/repo-deploy.key"
  if [ -s "$out" ]; then
    printf '%s' "$out"
    return 0
  fi
  nh_require_cmd age ssh git || return 2

  # Subshell + trap: the unwrapped operator identity never outlives the
  # decrypt. errexit is off in here (the caller tests our status), so
  # every step exits explicitly.
  if ! (
    set -euo pipefail
    idfile="$(mktemp "$root/id.XXXXXX")" || exit 1
    chmod 600 "$idfile" || exit 1
    trap 'rm -f "$idfile"' EXIT
    nh_unwrap_identity "$idfile" || exit 1
    age -d -i "$idfile" -o "$out.tmp" "$src" || exit 1
    chmod 600 "$out.tmp" || exit 1
  ); then
    rm -f "$out.tmp"
    nh_err "could not decrypt the repo deploy key at $src (wrong passphrase, or it predates the current operator key)"
    return 2
  fi
  if ! mv "$out.tmp" "$out"; then
    rm -f "$out.tmp"
    nh_err "could not stage the decrypted repo deploy key at $out"
    return 2
  fi
  nh_info "using the fleet repo deploy key from $src"
  printf '%s' "$out"
}

# nh_repo_git <git-args…> — git against the fleet REMOTE (clone, push,
# fetch, pull). Every network-facing git call goes through here so the
# credential choice is made in exactly one place. Purely local git
# (add, commit, rev-parse) keeps calling git directly.
#
# The deploy key is not written into the clone as core.sshCommand: its
# plaintext lives in this process's scratch root, so a persisted
# command would point at a path the next invocation has already wiped.
nh_repo_git() {
  local key="" rc=0 sshcmd
  key="$(nh_repo_deploy_key)" || rc=$?
  case "$rc" in
    0)
      # git re-splits GIT_SSH_COMMAND through the shell, so the key path
      # is quoted for it: the scratch root lives under $TMPDIR, which is
      # the operator's and may contain spaces.
      printf -v sshcmd 'ssh -i %q -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new' "$key"
      GIT_SSH_COMMAND="$sshcmd" git "$@"
      return $?
      ;;
    1) git "$@" ;;
    *) return 1 ;;
  esac
}
