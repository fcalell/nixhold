# Thin wrappers over gum so subcommands stay readable and we have
# one place to swap the TUI library if needed.

nh_prompt_input() {
  local label="$1" default="${2:-}"
  if [ -n "$default" ]; then
    gum input --placeholder "$label" --value "$default"
  else
    gum input --placeholder "$label"
  fi
}

nh_prompt_choose() {
  local header="$1"
  shift
  gum choose --header "$header" "$@"
}

nh_prompt_multi() {
  local header="$1"
  shift
  gum choose --no-limit --header "$header" "$@"
}

nh_prompt_confirm() {
  local label="$1"
  gum confirm "$label"
}

nh_prompt_password() {
  local label="$1"
  gum input --password --placeholder "$label"
}

# nh_prompt_gate <label> — pause before an action that seizes the whole
# terminal ($EDITOR). 0 = proceed, 1 = skip. A non-interactive run has
# nobody to answer, so it proceeds without pausing; callers must keep
# working with no terminal at all.
nh_prompt_gate() {
  local label="$1" reply=""
  if [ ! -t 0 ] && [ ! -t 2 ]; then
    return 0
  fi
  if command -v gum >/dev/null 2>&1 && [ -t 0 ]; then
    if gum confirm "$label?" --affirmative "go" --negative "skip"; then
      return 0
    fi
    return 1
  fi
  # Read from the terminal, not stdin: the caller may be inside a loop
  # fed by a redirect.
  printf 'press Enter to %s (or type s + Enter to skip) … ' "$label" >&2
  read -r reply </dev/tty || reply=""
  case "$reply" in
    s | S | skip) return 1 ;;
    *) return 0 ;;
  esac
}
