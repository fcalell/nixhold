# Where a host is built (ARCHITECTURE "Where a host is built"): the
# fleet at a pushed commit, fetched and built by the target as the
# operator, activated as root from the out path. The operator's
# machine instantiates nothing for another machine, and nothing but
# commands crosses its ssh connection.

# nh_fleet_rev <root> — HEAD's sha. A dirty tree is refused: a host
# builds the fleet at a commit, and a working-tree snapshot is not one
# anyone can check out again. Untracked files count — they are the
# ones a flake eval silently leaves out.
nh_fleet_rev() {
  local root="$1" dirty
  git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    nh_err "$root is not a git checkout — a host builds the fleet at a commit"
    return 1
  }
  dirty="$(git -C "$root" status --porcelain 2>/dev/null)" || return 1
  if [ -n "$dirty" ]; then
    nh_err "the checkout is dirty — a host builds the fleet at a commit, so commit first:"
    printf '%s\n' "$dirty" | sed 's/^/    /' >&2
    return 1
  fi
  git -C "$root" rev-parse HEAD
}

# nh_fleet_branch <root> — the branch HEAD is on; a detached HEAD has
# no ref for the target to fetch.
nh_fleet_branch() {
  git -C "$1" symbolic-ref --short -q HEAD || {
    nh_err "HEAD is detached — the target fetches a branch, so check one out"
    return 1
  }
}

# nh_fleet_push <root> — HEAD reaches the branch's upstream. Nothing
# to do when the upstream already contains it; a push otherwise, over
# nh_repo_git so the installer's clone key is used where there is one.
# A diverged upstream fails the push, and that failure is the answer:
# the target fetches from the forge, so HEAD has to be there.
nh_fleet_push() {
  local root="$1" branch upstream
  branch="$(nh_fleet_branch "$root")" || return 1
  upstream="$(git -C "$root" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)" || {
    nh_err "$branch has no upstream — git -C $root push -u origin $branch, then re-run"
    return 1
  }
  if git -C "$root" merge-base --is-ancestor HEAD "$upstream" 2>/dev/null; then
    return 0
  fi
  nh_info "pushing $branch to $upstream — the target fetches the fleet from the forge"
  nh_repo_git -C "$root" push -q || {
    nh_err "push failed — HEAD has to be on the forge before a host can build it"
    return 1
  }
}

# nh_fleet_repo — the fleet repo's forge slug (`owner/repo`): baked into
# the wrapped CLI by programs.nixhold, read off the layout in-tree.
nh_fleet_repo() {
  local repo="${NIXHOLD_REPO_URL:-}"
  if [ -z "$repo" ]; then
    repo="$(nh_layout repoUrl 2>/dev/null | jq -r '. // empty')" || repo=""
  fi
  [ -n "$repo" ] || {
    nh_err "layout.repoUrl is unset — a host fetches the fleet from its forge, so the fleet has to name one"
    return 1
  }
  printf '%s' "${repo%.git}"
}

# nh_fleet_ref <root> — the flake reference a running host builds
# from: the forge, the branch, the sha. Refuses dirty, pushes when the
# forge is behind, prints the reference. Diagnostics on stderr only:
# every caller takes this through a command substitution.
nh_fleet_ref() {
  local root="$1" repo sha branch
  repo="$(nh_fleet_repo)" || return 1
  sha="$(nh_fleet_rev "$root")" || return 1
  branch="$(nh_fleet_branch "$root")" || return 1
  nh_fleet_push "$root" || return 1
  printf 'git+ssh://git@github.com/%s?ref=refs/heads/%s&rev=%s' "$repo" "$branch" "$sha"
}

# nh_system_attr <platform> <name> — the flake attribute a system
# build realises.
nh_system_attr() {
  case "$1" in
    nixos) printf 'nixosConfigurations.%s.config.system.build.toplevel' "$2" ;;
    darwin) printf 'darwinConfigurations.%s.system' "$2" ;;
    *)
      nh_err "no system attribute for platform $1"
      return 1
      ;;
  esac
}

# nh_build_cmd <flake> <platform> <name> <dry:0|1> — the one build
# command, as a shell string: run as the operator, locally or through
# nh_ssh, it prints the out path and nothing else on stdout. The flake
# reference is single-quoted for the remote shell (a login shell that
# may be zsh: `?`, `&` and `#` are all in it).
nh_build_cmd() {
  local flake="$1" platform="$2" name="$3" dry="$4" attr dryflag=""
  attr="$(nh_system_attr "$platform" "$name")" || return 1
  [ "$dry" -eq 1 ] && dryflag="--dry-run "
  printf "nix build --no-link --print-out-paths %s'%s#%s'" "$dryflag" "$flake" "$attr"
}

# nh_activate_nixos_snippet <out> <mode> — the two steps nixos-rebuild
# wraps, for a snippet with nh_rsudo defined (lib/ssh.sh): the system
# profile set (not on `test`), then switch-to-configuration under
# systemd-run, so a dropped ssh connection does not kill the switch
# — the invocation nixos-rebuild itself uses. The nixos-version test is
# nixos-rebuild's guard against activating a path that is not a
# system closure.
nh_activate_nixos_snippet() {
  local out="$1" mode="$2"
  printf '[ -f %q/nixos-version ] || { echo "nixhold: %s is not a NixOS system closure" >&2; exit 1; }\n' "$out" "$out"
  case "$mode" in
    switch | boot) printf 'nh_rsudo nix-env -p /nix/var/nix/profiles/system --set %q || exit 1\n' "$out" ;;
  esac
  printf 'nh_rsudo systemd-run -E LOCALE_ARCHIVE -E NIXOS_INSTALL_BOOTLOADER=0 --collect --no-ask-password --pipe --quiet --service-type=exec --unit=nixhold-switch-to-configuration %q/bin/switch-to-configuration %q\n' "$out" "$mode"
}

# nh_activate_darwin <out> — nix-darwin's switch, as root: the system
# profile set and the closure's own activation script (its /etc guard
# and messages are the script's).
nh_activate_darwin() {
  local out="$1"
  [ -x "$out/activate" ] || {
    nh_err "$out is not a nix-darwin system closure"
    return 1
  }
  sudo nix-env -p /nix/var/nix/profiles/system --set "$out" || return 1
  sudo "$out/activate"
}
