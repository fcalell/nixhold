# nixhold secret show [<host>] <name>
#
# One plaintext on stdout, over the operator route. The way to read a
# credential the framework MINTED and a human types somewhere else:
# the syncthing GUI password is the case it exists for. Nothing is
# written, nothing is staged, and the plaintext goes to stdout alone:
# every message here is on stderr, so `nixhold secret show <host>
# <name> | pbcopy` copies the secret and not a log.
#
# Arguments resolve as `secret edit`'s do (nh_secret_resolve_name),
# with one difference: there is nothing to show without a name, so a
# lone argument is a SECRET name and a host on its own is an error.
cmd_secret_show() {
  local host="" name="" resolved
  if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    cat <<'EOF'
Usage: nixhold secret show [<host>] <name>

  <host> <name>   that secret on that host, decrypted to stdout.
  <name>          resolved across the fleet: a fleet-scoped secret
                  has one ciphertext, a host-scoped one declared on
                  several hosts opens a picker.
  network/<name>  that tailscale network's API client.
EOF
    return 0
  fi
  nh_require_cmd age jq nix

  # `network/<name>` is the API client of a tailscale-typed network, a
  # key file with no host (see "The tailnet's API client").
  if [ -z "${2:-}" ] && [ -n "${1:-}" ]; then
    local net netrc=0
    net="$(nh_tailnet_client_arg "$1")" || netrc=$?
    [ "$netrc" -ne 2 ] || return 1
    if [ "$netrc" -eq 0 ]; then
      nh_tailnet_client_show "$net"
      return $?
    fi
  fi

  if [ -n "${2:-}" ]; then
    host="$1"
    name="$2"
  elif [ -n "${1:-}" ]; then
    if nh_host_platform "$1" >/dev/null 2>&1; then
      nh_err "'$1' is a host — 'secret show' prints ONE secret, so name it: nixhold secret show $1 <name> ('nixhold secret list $1' lists them)"
      return 1
    fi
    resolved="$(nh_secret_resolve_name "$1" show)" || return 1
    host="${resolved%%$'\t'*}"
    name="$1"
  else
    nh_err "expected: nixhold secret show [<host>] <name>"
    return 1
  fi

  local platform sdir json target workdir
  platform="$(nh_host_platform "$host")" || {
    nh_err "host '$host' is not in this fleet — 'nixhold status --fleet' lists the roster"
    return 1
  }
  sdir="$(nh_worktree_secrets_dir)" || return 2
  json="$(nh_host_secrets "$host" "$platform")" || return 2
  if ! printf '%s' "$json" | jq -e --arg n "$name" 'has($n)' >/dev/null 2>&1; then
    nh_err "secret '$name' is not declared on $host (add nixhold.secrets.$name first)"
    return 1
  fi

  target="$(nh_secret_file "$sdir" "$host" "$name" "$(nh_secret_scope "$json" "$name")")"
  if [ ! -e "$target" ]; then
    nh_err "no ciphertext at $target — provision it with 'nixhold secret edit $host $name'"
    return 1
  fi
  workdir="$(nh_tmpdir secret)" || return 1
  nh_age_decrypt "$target" "$workdir/plain" || return 1
  # The scratch root is wiped by the dispatcher's exit handler; this
  # removes the plaintext the moment it has been printed anyway, since
  # a `show` piped into a pager can sit open for minutes.
  cat "$workdir/plain"
  rm -f "$workdir/plain"
}
