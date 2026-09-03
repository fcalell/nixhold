# nixhold update [--yes]
#
# The input-refresh workflow (lifecycle L6), runnable from any
# directory — nh_fleet_root resolves the checkout.
#   1. git pull --ff-only in the fleet root
#   2. nix flake update (flake.lock)
#   3. the inputs that moved, from the lock diff
#   4. hand off to `deploy` with no names: its picker (--yes = all)
# Nothing new from either step 1 or 2 exits early: there is nothing
# to deploy for.

cmd_update() {
  local yes=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --yes) yes=1; shift ;;
      -h | --help) echo "Usage: nixhold update [--yes]"; return 0 ;;
      -*) nh_err "unknown flag: $1"; return 1 ;;
      *) nh_err "extra arg: $1"; return 1 ;;
    esac
  done

  nh_require_cmd nix git jq || return 1
  local root
  root="$(nh_fleet_root)" || return 1

  # Scratch for the lock snapshot, wiped by the dispatcher's exit
  # handler (a trap here would replace it).
  local tmp
  tmp="$(nh_tmpdir update)" || return 1

  local head_before="" head_after=""
  nh_update_pull "$root" || return 1
  head_after="$(git -C "$root" rev-parse HEAD 2>/dev/null || true)"
  head_before="$_NH_UPDATE_HEAD_BEFORE"

  local lock="$root/flake.lock" moved=""
  [ -f "$lock" ] && cp "$lock" "$tmp/flake.lock.before"
  nh_info "nix flake update ($root)"
  ( cd "$root" && nix flake update ) || {
    nh_err "nix flake update failed"
    return 1
  }
  if [ -f "$tmp/flake.lock.before" ]; then
    moved="$(nh_update_lock_diff "$tmp/flake.lock.before" "$lock")"
  else
    moved="(new flake.lock)"
  fi

  if [ -z "$moved" ] && [ "$head_before" = "$head_after" ]; then
    nh_ok "nothing to update — inputs and checkout are already current"
    return 0
  fi
  [ "$head_before" = "$head_after" ] || nh_info "checkout moved ${head_before:0:12} → ${head_after:0:12}"
  if [ -n "$moved" ]; then
    nh_info "inputs moved:"
    printf '%s\n' "$moved" | sed 's/^/    /' >&2
    nh_info "commit the lock:  git -C $root commit -m 'flake: update inputs' flake.lock"
  fi

  . "$NIXHOLD_LIB_ROOT/deploy.sh"
  if [ "$yes" -eq 1 ]; then
    cmd_deploy --yes
  elif nh_tty; then
    cmd_deploy
  else
    nh_info "review above; deploy with: nixhold deploy <name>  (or re-run with --yes)"
  fi
}

# git pull --ff-only in the fleet root. A dirty tree is fine — the
# pull only touches tracked state the operator hasn't edited, and
# refusing would block the common "mid-edit, want fresh inputs" case.
# No upstream (or no git at all) is legitimate for a local-only
# fleet: warn and let the flake update proceed.
_NH_UPDATE_HEAD_BEFORE=""
nh_update_pull() {
  local root="$1"
  _NH_UPDATE_HEAD_BEFORE=""
  if ! git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
    nh_warn "$root is not a git checkout — skipping pull"
    return 0
  fi
  _NH_UPDATE_HEAD_BEFORE="$(git -C "$root" rev-parse HEAD 2>/dev/null || true)"
  if ! git -C "$root" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' >/dev/null 2>&1; then
    nh_warn "no upstream for the current branch — skipping pull"
    return 0
  fi
  # --no-rebase is load-bearing: with pull.rebase=true in the
  # operator's gitconfig, even --ff-only goes through the rebase
  # machinery, which refuses outright on unstaged changes.
  # nh_repo_git: the one place that decides between the operator's own
  # SSH credentials and the installer's baked deploy key.
  nh_info "git pull --ff-only ($root)"
  if ! nh_repo_git -C "$root" pull --ff-only --no-rebase >&2; then
    nh_err "git pull --ff-only failed — reconcile the checkout (rebase/merge or stash), then re-run"
    return 1
  fi
}

# nh_update_lock_diff <before> <after> — "<input>: <old> → <new>" per
# moved input. Compares locked revisions, not bytes: `nix flake
# update` rewrites the file even when no input moved.
nh_update_lock_diff() {
  jq -r -n --slurpfile a "$1" --slurpfile b "$2" '
    def rev: (.locked.rev // .locked.narHash // "?") | .[0:12];
    ($a[0].nodes // {}) as $old
    | ($b[0].nodes // {}) | to_entries[]
    | select(.key != "root")
    | select(.value.locked != null)
    | ($old[.key] | if . == null then "(new)" else rev end) as $was
    | (.value | rev) as $now
    | select($was != $now)
    | "\(.key): \($was) → \($now)"'
}
