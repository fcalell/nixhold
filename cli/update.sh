# nixhold update [--all]
#
# The input-refresh workflow (lifecycle L6), runnable from any
# directory — nh_fleet_root resolves the checkout.
#   1. git pull --ff-only in the fleet root
#   2. the pins that have no file yet, written (ARCHITECTURE "Pins")
#   3. the baseline: every host evaluates as the checkout stands
#   4. nix flake update (flake.lock)
#   5. every pin resolved against its `latest`; what moved: inputs
#      from the lock diff, pins by version
#   6. the eval gate: every host evaluates against the new lock and
#      pins; the warnings that appeared and the spine versions that
#      moved; a kernel move ends with "reboot required". A host that
#      fails restores the lock and the pin files and stops the verb
#      before deploy.
#   7. hand off to `deploy`: this machine, or --all
# Nothing new from step 1, 2, 4 or 5 exits early after the baseline:
# there is nothing to deploy for. All inputs and pins move or none —
# no per-input flag, because a held input is the "behind" state lint
# flags (rule 13) on every later run.

# The spine: the versions the gate reports when they move, per
# platform, as one Nix attrset off the host's configuration `h`
# (`h.config` and `h.pkgs` both reachable). `kernel` is the key that
# ends the report with "reboot required".
NH_SPINE_NIXOS='{
  kernel = h.config.boot.kernelPackages.kernel.version;
  systemd = h.pkgs.systemd.version;
  glibc = h.pkgs.glibc.version;
  openssh = h.pkgs.openssh.version;
}'
NH_SPINE_DARWIN='{
  openssh = h.pkgs.openssh.version;
  nix = h.config.nix.package.version;
}'
# An Android host's plan holds APKs pinned by hash, which no input
# moves: nothing to report, but the plan must still evaluate.
NH_SPINE_ANDROID='{ }'
# A NixOS host whose hardware report is declared and not yet written
# is pre-install: the framework's own guard (modules/hardware) blocks
# its build everywhere, so its toplevel cannot instantiate on any
# machine. The gate still reads its warnings and spine — neither
# forces `assertions` — and leaves `drv` null. Darwin has no report.
NH_PREINSTALL_NIXOS='(h.config.nixhold.hardware.facterReport != null
  && !builtins.pathExists h.config.nixhold.hardware.facterReport)'
NH_PREINSTALL_DARWIN='false'

cmd_update() {
  local all=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --all) all=1; shift ;;
      -h | --help) echo "Usage: nixhold update [--all]"; return 0 ;;
      -*) nh_err "unknown flag: $1"; return 1 ;;
      *) nh_err "extra arg: $1"; return 1 ;;
    esac
  done

  nh_require_cmd nix git jq curl || return 1
  local root
  root="$(nh_fleet_root)" || return 1

  # Scratch for the lock and pin snapshots, wiped by the dispatcher's
  # exit handler (a trap here would replace it).
  local tmp
  tmp="$(nh_tmpdir update)" || return 1

  local head_before="" head_after=""
  nh_update_pull "$root" || return 1
  head_after="$(git -C "$root" rev-parse HEAD 2>/dev/null || true)"
  head_before="$_NH_UPDATE_HEAD_BEFORE"

  # A pin declared and not yet written has no earlier state to gate
  # against, and a checkout that declares one does not build without
  # it: written first, so the baseline sees it.
  local new_pins=""
  new_pins="$(nh_pins_bootstrap)" || return 1
  if [ -n "$new_pins" ]; then
    nh_info "pins written:"
    printf '%s\n' "$new_pins" | sed 's/^/    /' >&2
  fi

  # The baseline runs before the lock is touched: a host that fails
  # here is broken by the checkout, not by an input, and restoring a
  # lock that never moved would report a fix that fixed nothing.
  nh_info "baseline: evaluating every host"
  nh_update_eval "$root" "$tmp" before || {
    nh_err "the checkout does not evaluate — fix it before updating inputs (flake.lock was not touched)"
    return 1
  }

  # A Ctrl-C between the update and the gate leaves the lock and the
  # pins moved and unchecked; the exit handler restores them until
  # the gate passes and disarms it.
  local lock="$root/flake.lock" moved="" moved_pins=""
  if [ -f "$lock" ]; then
    cp "$lock" "$tmp/flake.lock.before"
    _NH_UPDATE_LOCK="$lock"
    _NH_UPDATE_LOCK_BEFORE="$tmp/flake.lock.before"
  fi
  _NH_UPDATE_PINS="$tmp/pins"
  nh_at_exit nh_update_rollback
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
  moved_pins="$(nh_pins_move "$tmp/pins")" || {
    nh_update_rollback
    nh_err "a pin could not be resolved — flake.lock and the pin files restored, nothing deployed"
    return 1
  }

  if [ -z "$moved" ] && [ -z "$moved_pins" ] && [ -z "$new_pins" ] && [ "$head_before" = "$head_after" ]; then
    nh_update_disarm
    nh_ok "nothing to update — inputs, pins and checkout are already current"
    return 0
  fi
  [ "$head_before" = "$head_after" ] || nh_info "checkout moved ${head_before:0:12} → ${head_after:0:12}"
  if [ -n "$moved" ] || [ -n "$moved_pins" ]; then
    if [ -n "$moved" ]; then
      nh_info "inputs moved:"
      printf '%s\n' "$moved" | sed 's/^/    /' >&2
    fi
    if [ -n "$moved_pins" ]; then
      nh_info "pins moved:"
      printf '%s\n' "$moved_pins" | sed 's/^/    /' >&2
    fi
    nh_info "gate: evaluating every host against the new lock and pins"
    if ! nh_update_eval "$root" "$tmp" after; then
      nh_update_rollback
      nh_err "an input or a pin broke a host — flake.lock and the pin files restored, nothing deployed. What moved:"
      printf '%s\n' "$moved" "$moved_pins" | sed '/^$/d; s/^/    /' >&2
      nh_err "the fix belongs where the breakage is (nixhold for a framework module), not in a held pin"
      return 1
    fi
    nh_update_disarm
    if nh_update_report "$tmp"; then
      nh_warn "a kernel moved — deploy activates the userland; the new kernel runs only after a reboot"
    fi
  fi
  nh_update_disarm
  local files
  files="$(nh_update_commit_files "$root" "$moved" "$tmp/pins" "$new_pins")"
  [ -z "$files" ] || nh_info "commit what moved:  git -C $root commit -m 'flake: update inputs' $files"

  . "$NIXHOLD_LIB_ROOT/deploy.sh"
  if [ "$all" -eq 1 ]; then
    cmd_deploy --all
  else
    cmd_deploy
  fi
}

# The lock and pin restore, armed between `nix flake update` and a
# passed gate (see cmd_update); a no-op once disarmed. The pin
# snapshot dir holds `<name>.before` per moved pin and an index of
# "<name><TAB><worktree file>" lines, written by nh_pins_move.
_NH_UPDATE_LOCK=""
_NH_UPDATE_LOCK_BEFORE=""
_NH_UPDATE_PINS=""
nh_update_rollback() {
  local name file
  if [ -n "$_NH_UPDATE_LOCK_BEFORE" ] && [ -f "$_NH_UPDATE_LOCK_BEFORE" ]; then
    cp "$_NH_UPDATE_LOCK_BEFORE" "$_NH_UPDATE_LOCK" || return 1
    _NH_UPDATE_LOCK_BEFORE=""
    nh_warn "flake.lock restored to its pre-update state"
  fi
  if [ -n "$_NH_UPDATE_PINS" ] && [ -f "$_NH_UPDATE_PINS/index" ]; then
    while IFS=$'\t' read -r name file; do
      cp "$_NH_UPDATE_PINS/$name.before" "$file" || return 1
      nh_warn "pin $name restored to its pre-update state"
    done <"$_NH_UPDATE_PINS/index"
    _NH_UPDATE_PINS=""
  fi
  return 0
}

nh_update_disarm() {
  _NH_UPDATE_LOCK_BEFORE=""
  _NH_UPDATE_PINS=""
}

# nh_pins_bootstrap — write every declared pin whose file does not
# exist yet. Prints "<name>: (new) → <version>" per file written.
nh_pins_bootstrap() {
  local pins name decl file version
  pins="$(nh_fleet_pins)" || return 1
  for name in $(printf '%s' "$pins" | jq -r 'keys[]'); do
    decl="$(printf '%s' "$pins" | jq -c --arg n "$name" '.[$n]')"
    file="$(nh_pin_file "$name" "$(printf '%s' "$decl" | jq -r '.file')")" || return 1
    [ -e "$file" ] && continue
    mkdir -p "$(dirname "$file")" || return 1
    version="$(nh_pin_fetch "$name" "$(printf '%s' "$decl" | jq -r '.latest')" "$(printf '%s' "$decl" | jq -r '.manifest')" "$file")" || return 1
    printf '%s: (new) → %s\n' "$name" "$version"
  done
}

# nh_pins_move <snapshot-dir> — resolve every declared pin against
# its `latest`; a file whose version differs is snapshotted and
# rewritten. Prints "<name>: <old> → <new>" per move.
nh_pins_move() {
  local snap="$1" pins name decl file old new fetched
  pins="$(nh_fleet_pins)" || return 1
  mkdir -p "$snap" || return 1
  for name in $(printf '%s' "$pins" | jq -r 'keys[]'); do
    decl="$(printf '%s' "$pins" | jq -c --arg n "$name" '.[$n]')"
    file="$(nh_pin_file "$name" "$(printf '%s' "$decl" | jq -r '.file')")" || return 1
    old="$(nh_pin_version "$file")"
    fetched="$snap/$name.new"
    new="$(nh_pin_fetch "$name" "$(printf '%s' "$decl" | jq -r '.latest')" "$(printf '%s' "$decl" | jq -r '.manifest')" "$fetched")" || return 1
    [ "$new" != "$old" ] || continue
    cp "$file" "$snap/$name.before" || return 1
    printf '%s\t%s\n' "$name" "$file" >>"$snap/index"
    cp "$fetched" "$file" || return 1
    printf '%s: %s → %s\n' "$name" "$old" "$new"
  done
}

# nh_update_commit_files <root> <lock-diff> <snapshot-dir> <new-pins>
# — the paths that moved, relative to the fleet root, for the commit
# hint: the lock when an input did, every pin file written or moved.
nh_update_commit_files() {
  local root="$1" moved="$2" snap="$3" new_pins="$4" out="" name file pins
  [ -z "$moved" ] || out="flake.lock"
  if [ -f "$snap/index" ]; then
    while IFS=$'\t' read -r name file; do
      out="$out${out:+ }${file#"$root"/}"
    done <"$snap/index"
  fi
  if [ -n "$new_pins" ]; then
    pins="$(nh_fleet_pins)" || return 1
    while IFS= read -r name; do
      name="${name%%:*}"
      file="$(nh_pin_file "$name" "$(printf '%s' "$pins" | jq -r --arg n "$name" '.[$n].file')")" || return 1
      out="$out${out:+ }${file#"$root"/}"
    done <<<"$new_pins"
  fi
  printf '%s' "$out"
}

# nh_update_probe <root> <host> <platform> <out.json> — one eval per
# host: the toplevel drvPath (the instantiation is the check), the
# warnings, the spine. Evaluating instantiates without building, so
# a linux host probes fine from a Mac. Non-zero with nix's error on
# stderr.
nh_update_probe() {
  local root="$1" host="$2" platform="$3" out="$4" set spine pre product
  set="$(nh_config_set "$platform")" || return 1
  product="toplevel"
  case "$platform" in
    nixos) spine="$NH_SPINE_NIXOS"; pre="$NH_PREINSTALL_NIXOS" ;;
    darwin) spine="$NH_SPINE_DARWIN"; pre="$NH_PREINSTALL_DARWIN" ;;
    android) spine="$NH_SPINE_ANDROID"; pre="false"; product="plan" ;;
  esac
  nix eval --json --no-warn-dirty "$root#$set.$host" --apply "h: {
    drv = if $pre then null else h.config.system.build.$product.drvPath;
    warnings = h.config.warnings;
    spine = $spine;
  }" >"$out"
}

# nh_update_eval <root> <tmp> <side> — probe every host into
# <tmp>/<side>.<host>.json; side is before|after. Every host is
# probed even after one fails, so one run names them all.
nh_update_eval() {
  local root="$1" tmp="$2" side="$3" line host platform rc=0
  while IFS= read -r line; do
    host="${line%% *}"
    platform="${line##* }"
    [ -n "$host" ] || continue
    if nh_update_probe "$root" "$host" "$platform" "$tmp/$side.$host.json" 2>"$tmp/$side.$host.err"; then
      if jq -e '.drv == null' "$tmp/$side.$host.json" >/dev/null; then
        nh_info "  $host evaluates (not installed yet: no hardware report, so not instantiated)"
      else
        nh_info "  $host evaluates"
      fi
    else
      nh_err "$host does not evaluate:"
      sed 's/^/    /' "$tmp/$side.$host.err" >&2
      rc=1
    fi
  done < <(nh_hosts)
  return "$rc"
}

# nh_update_report <tmp> — per host: unchanged, or the warnings that
# appeared and the spine versions that moved. A pre-install host has
# no drv on either side, so it is never "unchanged": its warnings
# and spine are reported under a label that says so. True when a
# kernel moved on any host.
nh_update_report() {
  local tmp="$1" line host out label reboot=1
  while IFS= read -r line; do
    host="${line%% *}"
    [ -n "$host" ] || continue
    label="$host"
    jq -e '.drv == null' "$tmp/after.$host.json" >/dev/null && label="$host (not installed yet)"
    out="$(jq -r -n --slurpfile a "$tmp/before.$host.json" --slurpfile b "$tmp/after.$host.json" '
      $a[0] as $x | $b[0] as $y
      | if $y.drv != null and $x.drv == $y.drv then "unchanged" else
          ( ($y.warnings - $x.warnings)[] | "warning: \(.)" ),
          ( $y.spine | to_entries[]
            | select(.value != $x.spine[.key])
            | "\(.key): \($x.spine[.key]) → \(.value)" ),
          empty
        end')"
    case "$out" in
      unchanged) nh_info "$label: unchanged" ;;
      "") nh_info "$label: no new warning, spine unchanged" ;;
      *)
        nh_info "$label:"
        printf '%s\n' "$out" | sed 's/^/    /' >&2
        printf '%s\n' "$out" | grep -q '^kernel:' && reboot=0
        ;;
    esac
  done < <(nh_hosts)
  return "$reboot"
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
