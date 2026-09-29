# nixhold repo push
#
# Every checkout on this machine whose current branch is ahead of its
# upstream and not behind it is pushed there (ARCHITECTURE "nixhold
# repo"). The tracking refs are fetched first, so "not behind" is the
# forge's answer; a diverged branch is refused (pull first) and never
# forced, and no other branch is touched.

cmd_repo_push() {
  case "${1:-}" in
    "") ;;
    -h | --help)
      echo "Usage: nixhold repo push"
      return 0
      ;;
    *) nh_err "unknown argument: $1"; return 1 ;;
  esac
  nh_require_cmd git || return 1
  local rows tmp name path upstream counts ahead behind pushed=0 failed=()
  rows="$(nh_checkouts)" || return 1
  tmp="$(nh_tmpdir repo)" || return 1
  nh_checkouts_fetch "$tmp" <<<"$rows"
  while IFS=$'\t' read -r name path; do
    nh_checkout_present "$path" || continue
    git -C "$path" symbolic-ref -q HEAD >/dev/null || continue
    upstream="$(git -C "$path" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)" || continue
    if [ "$(cat "$tmp/$name.rc")" != 0 ]; then
      nh_err "$name: could not fetch — the forge is unreachable"
      failed+=("$name")
      continue
    fi
    counts="$(nh_checkout_counts "$path" "$upstream")" || { failed+=("$name"); continue; }
    read -r ahead behind <<<"$counts"
    [ "$ahead" -gt 0 ] || continue
    if [ "$behind" -gt 0 ]; then
      nh_err "$name has diverged from $upstream — nixhold repo pull first"
      failed+=("$name")
      continue
    fi
    if GIT_TERMINAL_PROMPT=0 nh_repo_git -C "$path" push -q "${upstream%%/*}" "HEAD:refs/heads/${upstream#*/}" </dev/null; then
      nh_ok "$name: pushed $ahead commit$([ "$ahead" -eq 1 ] || printf s) to $upstream"
      pushed=$((pushed + 1))
    else
      nh_err "$name: the push to $upstream failed"
      failed+=("$name")
    fi
  done <<<"$rows"
  [ "$pushed" -gt 0 ] || [ "${#failed[@]}" -gt 0 ] || nh_info "nothing to push"
  if [ "${#failed[@]}" -gt 0 ]; then
    nh_err "not pushed: ${failed[*]}"
    return 1
  fi
}
