# nixhold update [--yes]
#
# The input-refresh workflow (lifecycle L6), runnable from any
# directory — nh_fleet_root resolves the checkout.
#   1. git pull --ff-only in the fleet root
#   2. nix flake update (flake.lock)
#   3. per-host deploy --dry-run delta review
#   4. pick the hosts to deploy (gum multi-select; --yes = all)
# Nothing new from either step 1 or 2 exits early: there is no
# delta to review.

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

  local tmp
  tmp="$(mktemp -d -t nixhold-update.XXXXXX)"
  # shellcheck disable=SC2064 # expand $tmp now, it goes out of scope
  trap "rm -rf '$tmp'" EXIT

  local head_before="" head_after=""
  nh_update_pull "$root" || return 1
  head_after="$(git -C "$root" rev-parse HEAD 2>/dev/null || true)"
  head_before="$_NH_UPDATE_HEAD_BEFORE"

  # Compare the lock byte-for-byte: `nix flake update` rewrites the
  # file (timestamps and all) even when no input moved.
  local lock="$root/flake.lock" lock_changed=0
  [ -f "$lock" ] && cp "$lock" "$tmp/flake.lock.before"
  nh_info "nix flake update ($root)"
  ( cd "$root" && nix flake update ) || {
    nh_err "nix flake update failed"
    return 1
  }
  if [ ! -f "$tmp/flake.lock.before" ] || ! cmp -s "$tmp/flake.lock.before" "$lock"; then
    lock_changed=1
  fi

  if [ "$lock_changed" -eq 0 ] && [ "$head_before" = "$head_after" ]; then
    nh_ok "nothing to update — inputs and checkout are already current"
    return 0
  fi
  [ "$head_before" = "$head_after" ] || nh_info "checkout moved ${head_before:0:12} → ${head_after:0:12}"
  [ "$lock_changed" -eq 1 ] && nh_info "flake.lock changed"

  # Delta review. Eligible hosts are the ones this machine can
  # actually build/activate: every NixOS host (the target builds its
  # own closure) plus darwin only when we ARE the mac — deploy
  # refuses remote darwin, and a skip beats failing the whole run.
  local hosts entry line name platform rc
  local fleet=() eligible=() deltas=() unknown=()
  hosts="$(nh_update_hosts "$root")" || return 1
  [ -n "$hosts" ] || { nh_err "fleet has no hosts"; return 1; }
  while IFS= read -r line; do
    [ -n "$line" ] && fleet+=("$line")
  done <<<"$hosts"

  . "$NIXHOLD_LIB_ROOT/deploy.sh"

  # Iterated as an array, not a here-string: deploy keeps the
  # operator's stdin (bootstrap can still open an editor).
  for entry in "${fleet[@]}"; do
    name="${entry%% *}"
    platform="${entry##* }"
    if [ "$platform" = darwin ] && ! nh_update_is_this_mac "$name" "$root"; then
      nh_info "skip $name (darwin, deploys locally only)"
      continue
    fi
    eligible+=("$name")
    nh_info "── $name ($platform) — dry-run"
    rc=0
    cmd_deploy "$name" --dry-run --yes 2>&1 | tee "$tmp/$name.dry" >&2 || rc=$?
    if [ "$rc" -ne 0 ]; then
      nh_warn "$name: dry-run failed (host unreachable? config broken?) — delta unknown"
      unknown+=("$name")
    elif grep -qE 'will be (built|fetched)|these derivations will|these paths will' "$tmp/$name.dry"; then
      deltas+=("$name")
    fi
  done

  if [ "${#eligible[@]}" -eq 0 ]; then
    nh_warn "no host on this machine can be deployed — review the delta from the host itself"
    nh_update_commit_hint "$root" "$lock_changed"
    return 0
  fi

  # `dry-build` only names what it would build or fetch; a pure
  # activation-side change (or darwin's `check`, which builds rather
  # than reporting) shows nothing. So an empty delta set is treated
  # as "can't tell", not "nothing to do": offer every eligible host.
  local candidates=()
  if [ "${#deltas[@]}" -gt 0 ]; then
    candidates=("${deltas[@]}")
    [ "${#unknown[@]}" -gt 0 ] && candidates+=("${unknown[@]}")
  else
    nh_info "no delta detected in the dry-runs — offering every eligible host"
    candidates=("${eligible[@]}")
  fi

  local picked=()
  if [ "$yes" -eq 1 ]; then
    picked=("${candidates[@]}")
  elif [ ! -t 0 ] || [ ! -t 2 ]; then
    nh_info "review above; deploy with: nixhold deploy <name>  (or re-run with --yes)"
    nh_update_commit_hint "$root" "$lock_changed"
    return 0
  else
    local choice
    choice="$(nh_prompt_multi "Deploy which hosts?" "${candidates[@]}")" || choice=""
    if [ -z "$choice" ]; then
      nh_info "nothing selected"
      nh_update_commit_hint "$root" "$lock_changed"
      return 0
    fi
    while IFS= read -r line; do
      [ -n "$line" ] && picked+=("$line")
    done <<<"$choice"
  fi

  # The selection IS the confirmation, so deploy runs with --yes. A
  # failure on one host doesn't abandon the rest: report and carry on.
  local failed=()
  for name in "${picked[@]}"; do
    nh_info "── deploy $name"
    cmd_deploy "$name" --yes || failed+=("$name")
  done

  nh_update_commit_hint "$root" "$lock_changed"
  if [ "${#failed[@]}" -gt 0 ]; then
    nh_err "deploy failed: ${failed[*]}"
    return 1
  fi
  [ "${#picked[@]}" -gt 0 ] && nh_ok "deployed: ${picked[*]}"
  return 0
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
  nh_info "git pull --ff-only ($root)"
  if ! git -C "$root" pull --ff-only --no-rebase >&2; then
    nh_err "git pull --ff-only failed — reconcile the checkout (rebase/merge or stash), then re-run"
    return 1
  fi
}

# "<name> <platform>" per line, nixos first. Same probe as
# `status --fleet`: the two configuration sets are the fleet.
nh_update_hosts() {
  local root="$1" h
  for h in $(nix eval --json --no-warn-dirty "$root#nixosConfigurations" --apply 'builtins.attrNames' 2>/dev/null | jq -r '.[]?' || true); do
    printf '%s nixos\n' "$h"
  done
  for h in $(nix eval --json --no-warn-dirty "$root#darwinConfigurations" --apply 'builtins.attrNames' 2>/dev/null | jq -r '.[]?' || true); do
    printf '%s darwin\n' "$h"
  done
}

# Darwin hosts activate locally only (deploy refuses remote darwin).
# Match by hostname, but fall back to "the only mac in the fleet" —
# the fleet name and the macOS/MDM hostname routinely differ.
nh_update_is_this_mac() {
  local name="$1" root="$2" macs
  [ "$(uname -s)" = "Darwin" ] || return 1
  [ "$(hostname -s 2>/dev/null || hostname)" = "$name" ] && return 0
  macs="$(nix eval --json --no-warn-dirty "$root#darwinConfigurations" --apply 'builtins.attrNames' 2>/dev/null | jq -r 'length' || echo 0)"
  [ "$macs" = 1 ]
}

# The CLI auto-commits nothing outside the two install-time hardware
# files, so a moved lock is handed back as a command.
nh_update_commit_hint() {
  local root="$1" lock_changed="$2"
  [ "$lock_changed" -eq 1 ] || return 0
  nh_info "flake.lock updated — commit it:  git -C $root commit -m 'flake: update inputs' flake.lock"
}
