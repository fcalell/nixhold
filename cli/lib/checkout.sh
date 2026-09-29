# Checkouts (ARCHITECTURE "nixhold repo"): the fleet checkout and every
# declared repository on this machine, each meeting its forge, and the
# offers a refusal makes on a terminal. The fleet verbs sync the fleet
# checkout with the same function (ARCHITECTURE "Where a host is
# built").

# nh_checkouts — "<name>\t<path>" per checkout on this machine, the
# fleet first: the resolved fleet root, then the list programs.nixhold
# bakes ($NIXHOLD_REPOSITORIES, one "<name>\t<path>" per line, the
# host's nixhold.repositories). In-tree nothing is baked, and the fleet
# is the whole list.
nh_checkouts() {
  local root name path
  root="$(nh_fleet_root)" || return 1
  printf '%s\t%s\n' "${root##*/}" "$root"
  while IFS=$'\t' read -r name path; do
    [ -n "$name" ] && [ "$path" != "$root" ] || continue
    printf '%s\t%s\n' "$name" "$path"
  done <<<"${NIXHOLD_REPOSITORIES:-}"
}

# nh_checkout_present <dir> — the checkout exists: a declared one not
# on disk is its clone unit's to make, never a verb's.
nh_checkout_present() {
  git -C "$1" rev-parse --git-dir >/dev/null 2>&1
}

# nh_checkouts_fetch <tmp> — fetch every present checkout named on
# stdin ("<name>\t<path>") at once; <tmp>/<name>.rc holds each fetch's
# exit code. No prompt reaches a background fetch: a forge that wants
# one fails it.
nh_checkouts_fetch() {
  local tmp="$1" name path
  while IFS=$'\t' read -r name path; do
    nh_checkout_present "$path" || continue
    (
      rc=0
      GIT_TERMINAL_PROMPT=0 nh_repo_git -C "$path" fetch -q </dev/null >/dev/null 2>&1 || rc=$?
      echo "$rc" >"$tmp/$name.rc"
    ) &
  done
  wait
}

# nh_checkout_counts <dir> <upstream> — "<ahead> <behind>" of HEAD
# against the upstream's tracking ref, as fresh as the last fetch.
nh_checkout_counts() {
  git -C "$1" rev-list --left-right --count "HEAD...$2"
}

# nh_checkout_line <name> <dir> <fetch rc|-> — the status row,
# "<name>\t<branch>\t<sync>\t<tree>": the branch, where it stands
# against its upstream, the dirty count; or why there is nothing to
# compare.
nh_checkout_line() {
  local name="$1" dir="$2" fetch="$3" branch upstream counts ahead behind sync dirty
  if ! nh_checkout_present "$dir"; then
    printf '%s\t-\tmissing (its clone unit has not run)\t-\n' "$name"
    return 0
  fi
  dirty="$(git -C "$dir" status --porcelain | wc -l)"
  dirty="${dirty//[[:space:]]/}"
  [ "$dirty" -eq 0 ] && dirty=clean || dirty="$dirty dirty"
  if ! branch="$(git -C "$dir" symbolic-ref --short -q HEAD)"; then
    printf '%s\t(detached)\t-\t%s\n' "$name" "$dirty"
    return 0
  fi
  if ! upstream="$(git -C "$dir" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)"; then
    sync="no upstream"
  else
    counts="$(nh_checkout_counts "$dir" "$upstream")" || return 1
    read -r ahead behind <<<"$counts"
    case "$ahead:$behind" in
      0:0) sync="up to date" ;;
      *:0) sync="ahead $ahead" ;;
      0:*) sync="behind $behind" ;;
      *) sync="diverged +$ahead -$behind" ;;
    esac
    case "$fetch" in 0 | -) ;; *) sync="$sync, unreachable" ;; esac
  fi
  printf '%s\t%s\t%s\t%s\n' "$name" "$branch" "$sync" "$dirty"
}

# nh_checkout_sync <dir> [--allow-dirty] [--no-offer] [--fetched] — the
# checkout meets its forge: dirty refused (unless --allow-dirty: a
# fast-forward only touches files nobody edited, and git refuses the
# rest), the branch fetched (unless --fetched: the caller just did),
# HEAD fast-forwarded when the forge is ahead, a checkout that diverged
# refused with both sides named. Without it a checkout that fell behind
# builds its stale HEAD, and the tracking ref nh_fleet_push reads says
# the forge agrees. An unreachable forge stops it.
#
# On a terminal, and unless --no-offer, a refusal comes with its offer:
# commit the dirty tree, rebase the diverged branch, or both when the
# fast-forward touches an edited file. Declined, the refusal stands.
nh_checkout_sync() {
  local dir="$1" allow_dirty=0 offer=1 fetched=0 name branch upstream counts ahead behind
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --allow-dirty) allow_dirty=1 ;;
      --no-offer) offer=0 ;;
      --fetched) fetched=1 ;;
    esac
    shift
  done
  nh_tty || offer=0
  name="${dir##*/}"

  if [ "$allow_dirty" -eq 0 ] && [ -n "$(git -C "$dir" status --porcelain)" ]; then
    nh_err "$name is dirty — a verb builds a commit, not a working tree:"
    # The offer lists the tree itself.
    [ "$offer" -eq 1 ] || {
      git -C "$dir" status --short | sed 's/^/    /' >&2
      return 1
    }
    nh_checkout_commit "$dir" || return 1
    [ -z "$(git -C "$dir" status --porcelain)" ] || {
      nh_err "$name is still dirty — commit or stash the rest, then re-run"
      return 1
    }
  fi

  branch="$(git -C "$dir" symbolic-ref --short -q HEAD)" || {
    nh_err "$name: HEAD is detached — check out a branch"
    return 1
  }
  upstream="$(git -C "$dir" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)" || {
    nh_err "$name: $branch has no upstream — git -C $dir push -u origin $branch, then re-run"
    return 1
  }
  if [ "$fetched" -eq 0 ]; then
    GIT_TERMINAL_PROMPT=0 nh_repo_git -C "$dir" fetch -q || {
      nh_err "$name: could not fetch ${upstream%%/*} — the forge has to be reachable"
      return 1
    }
  fi

  counts="$(nh_checkout_counts "$dir" "$upstream")" || return 1
  read -r ahead behind <<<"$counts"
  [ "$behind" -gt 0 ] || return 0
  if [ "$ahead" -gt 0 ]; then
    nh_err "$name and $upstream have diverged:"
    nh_err "  here only ($ahead):"
    git -C "$dir" log --oneline "$upstream..HEAD" | sed 's/^/      /' >&2
    nh_err "  $upstream only ($behind):"
    git -C "$dir" log --oneline "HEAD..$upstream" | sed 's/^/      /' >&2
    [ "$offer" -eq 1 ] || {
      nh_err "rebase or merge, then re-run"
      return 1
    }
    nh_checkout_rebase "$dir" "$upstream" "$allow_dirty"
    return
  fi

  nh_info "$name: fast-forwarding to $upstream ($behind new commit$([ "$behind" -eq 1 ] || printf s))"
  git -C "$dir" merge --ff-only -q "$upstream" >&2 && return 0
  nh_err "$name: the fast-forward to $upstream touches a file edited here"
  [ "$offer" -eq 1 ] || {
    nh_err "commit or stash it, then re-run"
    return 1
  }
  nh_checkout_commit "$dir" && nh_checkout_rebase "$dir" "$upstream" "$allow_dirty"
}

# nh_checkout_commit <dir> — offer to commit a dirty checkout: its
# short status, a yes, then the message in $EDITOR, starting from the
# draft hook's when one is set. What is staged commits; nothing staged
# stages everything. A no or an empty message commits nothing and puts
# back an index the offer staged. 0 when a commit was made.
nh_checkout_commit() {
  local dir="$1" name staged=0 tmp
  name="${dir##*/}"
  git -C "$dir" status --short | sed 's/^/    /' >&2
  nh_prompt_confirm "Commit $name?" || return 1
  if git -C "$dir" diff --cached --quiet; then
    git -C "$dir" add -A || return 1
    staged=1
  fi
  tmp="$(nh_tmpdir commit)" || return 1
  nh_checkout_draft "$dir" >"$tmp/MSG"
  if git -C "$dir" commit -q -e -F "$tmp/MSG"; then
    nh_ok "$name: committed $(git -C "$dir" log -1 --format='%h %s')"
    return 0
  fi
  [ "$staged" -eq 0 ] || git -C "$dir" reset -q
  nh_warn "$name: nothing committed"
  return 1
}

# nh_checkout_draft <dir> — the draft hook's message for what is staged
# in <dir> ($NIXHOLD_REPO_DRAFT, programs.nixhold.repo.draft: the short
# status and the staged diff on stdin, run in the checkout), or nothing
# when there is no hook or it gave no message.
nh_checkout_draft() {
  local dir="$1" hook="${NIXHOLD_REPO_DRAFT:-}" out=""
  [ -n "$hook" ] || return 0
  nh_info "drafting the message"
  out="$(
    {
      git -C "$dir" status --short
      echo
      git -C "$dir" diff --cached
    } | (cd "$dir" && "$hook")
  )" || out=""
  if [ -z "$out" ]; then
    nh_warn "the draft hook gave no message — the editor starts empty"
    return 0
  fi
  printf '%s\n' "$out"
}

# nh_checkout_rebasing <dir> — a rebase is in progress.
nh_checkout_rebasing() {
  local p
  for p in rebase-merge rebase-apply; do
    [ -d "$(git -C "$1" rev-parse --path-format=absolute --git-path "$p")" ] && return 0
  done
  return 1
}

# nh_checkout_rebase <dir> <upstream> <autostash 0|1> — offer to rebase
# HEAD's commits onto the upstream. A conflict goes to the resolve hook
# ($NIXHOLD_REPO_RESOLVE, programs.nixhold.repo.resolve: a brief as $1,
# run in the checkout on the terminal) when one is set; a rebase still
# in progress after it, or with no hook, is aborted, the checkout as it
# was. Nothing is pushed. 0 when HEAD sits on the upstream.
nh_checkout_rebase() {
  local dir="$1" upstream="$2" autostash="$3" name branch mine theirs flags=()
  name="${dir##*/}"
  nh_prompt_confirm "Rebase $name's commits onto $upstream?" || return 1
  branch="$(git -C "$dir" symbolic-ref --short -q HEAD)" || return 1
  mine="$(git -C "$dir" log --oneline "$upstream..HEAD")"
  theirs="$(git -C "$dir" log --oneline "HEAD..$upstream")"
  [ "$autostash" -eq 0 ] || flags+=(--autostash)
  if ! git -C "$dir" rebase -q "${flags[@]}" "$upstream" >&2 &&
    [ -n "${NIXHOLD_REPO_RESOLVE:-}" ] && nh_checkout_rebasing "$dir"; then
    nh_info "$name: handing the conflict to the resolve hook"
    (cd "$dir" && "$NIXHOLD_REPO_RESOLVE" "$(nh_checkout_brief "$dir" "$branch" "$upstream" "$mine" "$theirs")") || true
  fi
  if nh_checkout_rebasing "$dir"; then
    git -C "$dir" rebase --abort
    nh_err "$name: the rebase onto $upstream did not finish — aborted, the checkout is as it was"
    return 1
  fi
  git -C "$dir" merge-base --is-ancestor "$upstream" HEAD || {
    nh_err "$name: HEAD is not on $upstream after the rebase"
    return 1
  }
  nh_ok "$name: rebased onto $upstream"
}

# nh_checkout_brief <dir> <branch> <upstream> <mine> <theirs> — what the
# resolve hook is handed: the facts of the stopped rebase and the goal.
nh_checkout_brief() {
  local dir="$1" branch="$2" upstream="$3" mine="$4" theirs="$5"
  cat <<EOF
A rebase of $branch onto $upstream stopped on a conflict in $dir.

Commits on $branch being replayed:
$mine

Commits on $upstream they are replayed onto:
$theirs

Conflicted now:
$(git -C "$dir" diff --name-only --diff-filter=U)

Resolve each conflict keeping the intent of both sides, stage it, and
run \`git rebase --continue\` until the rebase finishes. Do not push. A
conflict whose right answer needs the operator's judgement is theirs to
decide: ask. Leaving the rebase unfinished aborts it.
EOF
}
