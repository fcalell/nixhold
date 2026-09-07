# SSH helpers shared by host-install / host-key / deploy / logs.
#
# Host-key policy. These connections carry the fleet key (which every
# host holds) and run activation on a machine, and the fleet commits
# every host's public key as keys/hosts/<host>.pub — so a caller that
# knows WHICH fleet host is at the other end says so (`nh_ssh <target>
# --host <name>`) and the connection is PINNED to the key the fleet
# knows for it: a scratch known_hosts under the process scratch root
# plus StrictHostKeyChecking=yes.
#
# Trust-on-first-use survives only where the fleet has nothing to pin
# to: a host whose key it has never seen (a machine adopted with `host
# key`), and the installer ISO, whose host key is random per boot —
# `host install --remote` therefore passes no --host at all.

# nh_ssh_pin_keys <host> — the pubkey lines the fleet is willing to
# accept from <host>, one per line; non-zero when it knows none.
# Exactly one line today: keys/hosts/<host>.pub, written at install and
# re-recorded by `host key`.
nh_ssh_pin_keys() {
  local host="$1" pub line
  [ -n "$host" ] || return 1
  pub="$(nh_committed_host_pub "$host" 2>/dev/null)" || return 1
  line="$(nh_pubkey_line "$pub")" || return 1
  printf '%s\n' "$line"
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
    # verification on exactly the connections that carry the fleet key
    # and drive activation, so it is a hard failure instead.
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
      nh_info "$hostpart was pinned to $host's committed key — if ssh reported a host key mismatch, the machine runs a key the fleet does not know; check its fingerprint out of band, then 'nixhold host key $host' records the machine's live key as keys/hosts/$host.pub"
    fi
    return "$rc"
  fi

  nh_info "no committed host key for ${host:-$hostpart} — accepting $hostpart's key on first use"
  ssh -o StrictHostKeyChecking=accept-new "$target" "$@"
}

# ---------------------------------------------------------------------
# Remote privilege escalation.
#
# The operator has no passwordless sudo (modules/identity/nixos.nix
# declares the `password` secret `required` instead), so every remote
# verb that escalates has to get a password to the target's sudo. Three
# candidate mechanisms, and why this one:
#
#   `ssh -t … sudo …` — sudo prompts on the allocated pty. But the pty
#   also turns the remote command's STDOUT into a terminal: newlines
#   become CRLF, which silently corrupts the one payload that matters
#   here — a remote read is captured on stdout byte for byte).
#   Stripping CRs back out is a guess about which bytes were ours.
#
#   `ssh -t … sudo -v` once, then `sudo -n` — sudo's timestamp is per
#   tty AND per session by default (`tty_tickets`), so a second ssh
#   session does not inherit it. Making it inherit means editing the
#   fleet's sudoers defaults, which is a worse posture than the one
#   being removed.
#
#   `sudo -S -p ''` reading the password from STDIN — no pty, so stdout
#   stays exactly the bytes the remote command wrote. sudo's tgetpass
#   reads the password one byte at a time and stops at the newline, so
#   whatever follows on stdin is still there for the command itself
#   (that is what lets `nh_fleet_key_install_remote` send the password
#   line and then the fleet key on the same stdin). That is what is
#   implemented here.
#
# The password is prompted ONCE per CLI process, kept in a shell
# variable, and reaches the target as the first line of the ssh
# session's stdin — never on disk, never in an argv (the remote side
# holds it in a variable and pipes it with the `printf` builtin), never
# in the environment.
#
# A wrong password is caught by a GATE before the snippet runs, not by
# the first `nh_rsudo` inside it. Two reasons. A snippet that escalates
# more than once mutates the machine before it fails — the fleet-key
# install would have created /etc/nixhold and written the key but not
# its pubkey, and the operator would be left reading a half-applied step
# out of an error message. And `sudo -S` on a wrong password says
# "Sorry, try again" and reads MORE lines looking for a retry: every
# nh_rsudo here hands sudo a private `printf` pipe rather than the
# session stdin, so those reads hit EOF instead of eating the private
# key travelling behind the password — but that safety is a property of
# how nh_rsudo is written, and a gate does not depend on remembering
# it. The gate is one `sudo -k -v`: `-k` ignores any cached timestamp
# so it tests the password we were actually handed, and (per sudo's
# own documentation) does not write one either, which is why nh_rsudo
# still pipes the password on every call.

# The exit status the remote preamble uses to say "the password was
# rejected", as opposed to any status the snippet itself might return.
# nh_ssh_sudo turns it back into a re-prompt.
_NH_SUDO_AUTH_RC=111

# _NH_SUDO_PW — the cached password. `nh_sudo_password_ensure` sets it
# in the CALLER's shell, so it must not be invoked from a command
# substitution (the subshell would throw the cache away and the
# operator would be asked again).
_NH_SUDO_PW=""
_NH_SUDO_PW_SET=0

# nh_sudo_password_ensure [label] — make $_NH_SUDO_PW hold the
# operator's sudo password, prompting once. Non-zero when there is
# nobody to ask.
nh_sudo_password_ensure() {
  local label="${1:-the remote host}" pw=""
  [ "$_NH_SUDO_PW_SET" -eq 1 ] && return 0
  if [ ! -r /dev/tty ]; then
    nh_err "sudo on $label needs the operator's password and there is no terminal to ask on — run this verb interactively"
    return 1
  fi
  if command -v gum >/dev/null 2>&1; then
    pw="$(gum input --password --placeholder "sudo password for $label" </dev/tty)" || return 1
  else
    # The prompt goes to the terminal, not stderr: callers that
    # swallow stderr (best-effort probes) must still be answerable.
    printf 'sudo password for %s: ' "$label" >/dev/tty
    IFS= read -rs pw </dev/tty || return 1
    printf '\n' >/dev/tty
  fi
  _NH_SUDO_PW="$pw"
  _NH_SUDO_PW_SET=1
}

# nh_sudo_password_forget — drop the cached password so the next
# nh_sudo_password_ensure asks again. A mistyped password would
# otherwise be cached for the life of the process and fail every
# remaining verb with the same error.
nh_sudo_password_forget() {
  _NH_SUDO_PW=""
  _NH_SUDO_PW_SET=0
}

# nh_sudo_preamble_remote — a shell snippet for the TARGET's shell that
# defines `nh_rsudo <cmd…>`. It consumes the first line of stdin as the
# password (empty when the connection is already root), leaving the
# rest of the stream for the command that follows, and refuses to go
# any further if that password is not accepted.
nh_sudo_preamble_remote() {
  cat <<EOF
IFS= read -r _nh_pw || _nh_pw=""
if [ "\$(id -u)" -ne 0 ]; then
  # The gate. sudo's own stderr is left visible: "Sorry, try again" and
  # "user is not in the sudoers file" are different problems and only
  # sudo can tell them apart.
  if ! printf '%s\\n' "\$_nh_pw" | sudo -S -p '' -k -v; then
    echo "nixhold: sudo did not accept the operator's password" >&2
    exit $_NH_SUDO_AUTH_RC
  fi
fi
nh_rsudo() {
  if [ "\$(id -u)" -eq 0 ]; then
    "\$@"
  else
    printf '%s\\n' "\$_nh_pw" | sudo -S -p '' "\$@"
  fi
}
EOF
}

# nh_sudo_preamble_local — the same `nh_rsudo` for a snippet run by a
# local `sh -c`, where sudo has a terminal and prompts for itself. No
# password line is consumed.
nh_sudo_preamble_local() {
  cat <<'EOF'
nh_rsudo() {
  if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi
}
EOF
}

# nh_ssh_sudo <target> [--host <fleet-host>] -- <snippet>
#
# Run <snippet> on <target> with `nh_rsudo` available to it. Pins the
# host key exactly as nh_ssh does (--host).
#
# STDIN of this function becomes the snippet's stdin, after the
# password line is consumed by the preamble — pass `</dev/null` when
# the snippet reads nothing, or the file to stream when it does. Never
# hand it a terminal: the forwarder would block on it.
nh_ssh_sudo() {
  local target="$1" host="" snippet pw=""
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
  snippet="${1:-}"

  # A root connection needs no password, but the preamble always eats
  # one line — send an empty one so the wire format does not depend on
  # who is connecting.
  case "${target%%@*}" in
    root) ;;
    *)
      nh_sudo_password_ensure "$target" || return 1
      pw="$_NH_SUDO_PW"
      ;;
  esac

  local hostargs=()
  [ -n "$host" ] && hostargs=(--host "$host")

  # Process substitution, not a pipe into nh_ssh: under `pipefail` a
  # forwarder that takes SIGPIPE when the remote exits early would turn
  # a successful run into a failure.
  local rc=0
  nh_ssh "$target" "${hostargs[@]}" -- "$(nh_sudo_preamble_remote)
$snippet" < <(
    printf '%s\n' "$pw"
    cat
  ) || rc=$?

  if [ "$rc" -eq "$_NH_SUDO_AUTH_RC" ]; then
    # Nothing ran on the target — the gate stopped before the snippet.
    nh_err "sudo on $target rejected the password — re-run the verb and retype it"
    nh_sudo_password_forget
  fi
  return "$rc"
}
