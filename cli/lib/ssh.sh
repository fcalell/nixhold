# SSH helpers shared by host-install / deploy / logs.

# Run a command on a remote host, exit non-zero on failure.
# Usage: nh_ssh user@host -- cmd args...
nh_ssh() {
  local target="$1"
  shift
  if [ "${1:-}" = "--" ]; then shift; fi
  ssh -o StrictHostKeyChecking=accept-new "$target" "$@"
}

# Resolve a host's deploy address — prefers tailnet, falls back to
# any internet-typed network with a non-null address.
nh_deploy_addr() {
  local host="$1" platform="$2"
  local addrs
  addrs="$(nh_host_eval "$host" "$platform" \
    "nixhold.fleet.derived.address.$host")"
  printf '%s' "$addrs" \
    | jq -r '.tailnet // (to_entries | map(select(.value != null)) | first | .value // empty)'
}
