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
