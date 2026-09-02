# SSH helpers shared by host-install / host-escrow / host-install-key /
# host-rotate-key / deploy / logs.
#
# Host-key policy. These connections carry a host's PRIVATE key in both
# directions (`nh_read_live_host_key` reads it off the machine,
# `nh_install_host_key_remote` ships it there), and the fleet already
# commits every host's public key as keys/hosts/<host>/host.pub — so a
# caller that knows WHICH fleet host is at the other end says so
# (`nh_ssh <target> --host <name>`) and the connection is PINNED to the
# key(s) the fleet knows for it: a scratch known_hosts under the process
# scratch root plus StrictHostKeyChecking=yes.
#
# Trust-on-first-use survives only where the fleet has nothing to pin
# to: a host whose key it has never seen (first `host add` / first
# `host escrow`), and the installer ISO, whose host key is random per
# boot — `host install --remote` therefore passes no --host at all.

# nh_ssh_pin_keys <host> — the pubkey lines the fleet is willing to
# accept from <host>, one per line; non-zero when it knows none.
#
# Normally exactly one: the committed recipient. During a rotation the
# repo already names the NEW key while the machine still answers with
# the old one, so `host rotate-key` records the superseded pubkey as
# host.pub.prev beside the superseded escrow and deletes both once the
# new key is installed — for that window, and only then, the previous
# key is accepted too. That is what makes the connection that SHIPS the
# rotated key pinnable at all.
nh_ssh_pin_keys() {
  local host="$1" pub prev line found=0
  [ -n "$host" ] || return 1
  pub="$(nh_committed_host_pub "$host" 2>/dev/null)" || pub=""
  if [ -n "$pub" ] && line="$(nh_pubkey_line "$pub")"; then
    printf '%s\n' "$line"
    found=1
  fi
  prev="$NIXHOLD_CACHE_DIR/host-keys/$host/host.pub.prev"
  if line="$(nh_pubkey_line "$prev")"; then
    printf '%s\n' "$line"
    found=1
  fi
  [ "$found" -eq 1 ]
}

# nh_ssh_known_hosts <hostpart> <host> — write a scratch known_hosts
# pinning <hostpart> to the keys of fleet host <host> and print its
# path. Exit codes are distinct on purpose:
#   1  the fleet knows no key for <host> — first contact, TOFU is the
#      honest answer
#   2  it knows one but the file could not be written — an
#      infrastructure failure, which must NOT decay into TOFU
#
# ssh looks the destination up as typed, and nh_ssh targets are
# "<user>@<addr>" with no port, so one entry per accepted key is enough
# (CheckHostIP=no keeps ssh from demanding a second entry keyed on the
# resolved address). The file lives under the process scratch root, so
# the dispatcher's exit handler wipes it.
nh_ssh_known_hosts() {
  local hostpart="$1" host="$2" keys d kh line
  keys="$(nh_ssh_pin_keys "$host")" || return 1
  d="$(nh_tmpdir known-hosts)" || return 2
  kh="$d/known_hosts"
  : >"$kh" || return 2
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf '%s %s\n' "$hostpart" "$line" >>"$kh"
  done <<<"$keys"
  printf '%s' "$kh"
}

# nh_ssh_pin_opts <host> <hostpart> — the same pin as a single string
# of ssh options, for the drivers that take one ($NIX_SSHOPTS). Same
# split as nh_ssh_known_hosts — 1 "the fleet knows no key", 2 "it does,
# but the pin is not usable here" — since the caller's fallback differs
# per case. Those variables are word-split by the tool that consumes
# them and offer no quoting, so a scratch path containing whitespace is
# a 2, not a mis-split command line.
nh_ssh_pin_opts() {
  local host="$1" hostpart="$2" kh rc=0
  kh="$(nh_ssh_known_hosts "$hostpart" "$host")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    return "$rc"
  fi
  case "$kh" in
    *[[:space:]]*) return 2 ;;
  esac
  printf -- '-o UserKnownHostsFile=%s -o GlobalKnownHostsFile=/dev/null -o StrictHostKeyChecking=yes -o CheckHostIP=no -o UpdateHostKeys=no' "$kh"
}

# Run a command on a remote host, exit non-zero on failure.
# Usage: nh_ssh user@host [--host <fleet-host>] -- cmd args...
#
# --host names the FLEET host the target is expected to be, which is
# what makes the connection pinnable; without it (or when the fleet
# holds no key for that host) the host key is accepted on first use,
# and said so.
nh_ssh() {
  local target="$1" host="" kh hostpart rc=0 pinrc=0
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --host)
        host="${2:-}"
        shift 2
        ;;
      --)
        shift
        break
        ;;
      *) break ;;
    esac
  done
  hostpart="${target##*@}"

  if [ -n "$host" ]; then
    kh="$(nh_ssh_known_hosts "$hostpart" "$host")" || pinrc=$?
    # 2 = the fleet HAS a key for $host but the pin could not be
    # staged. Falling through to first-use trust there would drop the
    # verification on exactly the connections that carry private keys,
    # so it is a hard failure instead.
    if [ "$pinrc" -eq 2 ]; then
      nh_err "could not stage the host-key pin for $host — refusing to connect to $hostpart unverified"
      return 1
    fi
  fi

  if [ "$pinrc" -eq 0 ] && [ -n "$host" ]; then
    # UpdateHostKeys=no keeps the pin file exactly as written;
    # GlobalKnownHostsFile=/dev/null keeps a system-wide entry from
    # standing in for the fleet's own record.
    ssh -o "UserKnownHostsFile=$kh" -o GlobalKnownHostsFile=/dev/null \
      -o StrictHostKeyChecking=yes -o CheckHostIP=no -o UpdateHostKeys=no \
      "$target" "$@" || rc=$?
    if [ "$rc" -eq 255 ]; then
      # Every remote verb pins the same way, so a drifted machine is
      # unreachable from here on purpose: reconcile ON the machine
      # (the local paths read /etc/ssh directly, no ssh involved).
      nh_info "$hostpart was pinned to $host's committed key — if ssh reported a host key mismatch, the machine runs a key the fleet does not know; log in on it (console, or your own ssh after checking its fingerprint out of band) and run 'nixhold host escrow $host' there to adopt that key, or 'nixhold host install-key $host' to put the fleet's back"
    fi
    return "$rc"
  fi

  nh_info "no committed host key for ${host:-$hostpart} — accepting $hostpart's key on first use"
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
