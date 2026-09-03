# The fleet view: `nixhold.fleet` (hosts, arch, networks, derived
# addresses) evaluated ONCE per CLI process and kept as JSON under the
# scratch root. Every roster question — which hosts exist, which
# platform a host is, how to reach it, what to offer in a picker — is
# answered from it, so no verb runs its own `nix eval` for the roster.
#
# The memo is a file, not a shell variable: command-substitution
# callers run in subshells and could not write a variable back. A verb
# that rewrites hostsFile calls nh_fleet_view_reset so the next reader
# sees the new roster.

# nh_fleet_view — the view as JSON on stdout:
#   { hosts:   { <name>: { arch, platform, networks, publicIp, publicFqdn } },
#     network: { <name>: { type, magicDnsSuffix, domain } },
#     address: { <host>: { <network>: <addr|null> } } }
# Non-zero when the fleet has no host to read it from, or the eval
# fails (the error is nix's own).
nh_fleet_view() {
  local root memo fleet json set
  root="$(nh_tmp_root)" || return 1
  memo="$root/fleet.json"
  if [ -s "$memo" ]; then
    cat "$memo"
    return 0
  fi
  fleet="$(nh_fleet_root)" || return 1
  # `profile` and `modules` are module values, not data — project the
  # host entries down to what is serialisable. `null` = the set is
  # empty; the darwin set is tried only then, so a mixed fleet costs
  # one eval.
  for set in nixosConfigurations darwinConfigurations; do
    json="$(nix eval --json --no-warn-dirty "$fleet#$set" --apply '
      cs:
      let f = (builtins.head (builtins.attrValues cs)).config.nixhold.fleet;
      in if cs == { } then null else {
        hosts = builtins.mapAttrs (n: h: {
          inherit (h) arch networks publicIp publicFqdn;
          platform = if builtins.match ".*-darwin" h.arch != null then "darwin" else "nixos";
        }) f.hosts;
        inherit (f) network;
        address = f.derived.address;
      }')" || return 1
    if [ "$json" != "null" ]; then
      printf '%s' "$json" >"$memo" || return 1
      printf '%s' "$json"
      return 0
    fi
  done
  nh_err "fleet has no hosts yet"
  return 1
}

nh_fleet_view_reset() {
  local root
  root="$(nh_tmp_root)" || return 0
  rm -f "$root/fleet.json"
}

# nh_hosts [platform] — "<name> <platform>" per line, nixos first,
# optionally only one platform.
nh_hosts() {
  local only="${1:-}"
  nh_fleet_view | jq -r --arg p "$only" '
    .hosts | to_entries
    | map(select($p == "" or .value.platform == $p))
    | sort_by(.value.platform != "nixos", .key)[]
    | "\(.key) \(.value.platform)"'
}

# nh_all_hosts — every host name, one per line.
nh_all_hosts() {
  nh_hosts | cut -d' ' -f1
}

# nh_host_platform <host> — "nixos" | "darwin"; non-zero when the
# host is not in the fleet.
nh_host_platform() {
  local host="$1" p
  p="$(nh_fleet_view | jq -r --arg h "$host" '.hosts[$h].platform // empty')" || return 2
  [ -n "$p" ] || return 1
  printf '%s' "$p"
}

# nh_host_arch <host> — the host's system double.
nh_host_arch() {
  nh_fleet_view | jq -r --arg h "$1" '.hosts[$h].arch // empty'
}

# nh_host_field <host> <field> — one host field from the view, raw
# (empty when null).
nh_host_field() {
  nh_fleet_view | jq -r --arg h "$1" --arg f "$2" '.hosts[$h][$f] // empty'
}

# nh_deploy_addr <host> — how the CLI reaches <host>: its address on
# the tailscale-typed network when that resolves, else the first
# non-null address on any other network. Empty when nothing resolves.
nh_deploy_addr() {
  nh_fleet_view | jq -r --arg h "$1" '
    ((.network | to_entries | map(select(.value.type == "tailscale")) | .[0].key) // "") as $ts
    | .address[$h] // {}
    | (.[$ts] // (to_entries | map(select(.value != null)) | .[0].value)) // empty'
}

# nh_layout <key> — nixhold.layout.<key> as JSON, read through any
# host (mkFleet sets layout uniformly).
nh_layout() {
  local key="$1" first platform
  first="$(nh_hosts 2>/dev/null | head -n1)" || first=""
  if [ -z "$first" ]; then
    nh_err "fleet has no hosts yet — layout cannot be probed"
    return 1
  fi
  platform="${first##* }"
  nh_host_eval "${first%% *}" "$platform" "nixhold.layout.$key"
}

# nh_tty — true when the operator can be asked something.
nh_tty() {
  [ -t 0 ] && [ -t 2 ]
}

# nh_pick_host <header> [platform] — one host from the roster (gum).
# Prints the name; non-zero on cancel or an empty roster. Callers
# check nh_tty first and print their usage line when there is nobody
# to ask.
nh_pick_host() {
  local header="$1" only="${2:-}" rows
  rows="$(nh_hosts "$only" | awk '{ printf "%-16s %s\n", $1, $2 }')" || return 1
  [ -n "$rows" ] || {
    nh_err "no ${only:+$only }host in the fleet"
    return 1
  }
  printf '%s\n' "$rows" | gum choose --header "$header" | awk '{ print $1 }'
}

# nh_pick_hosts <header> <name…> — a multi-select over the given
# names, one per line on stdout; non-zero when nothing was picked.
nh_pick_hosts() {
  local header="$1" out
  shift
  out="$(gum choose --no-limit --header "$header" "$@")" || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}
