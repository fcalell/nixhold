# Rule: keys/login.pub is tracked and names at least one key.
#
# It is the fleet's ONE login mechanism:
# `nixhold.fleet.derived.operatorAuthorizedKeys` is exactly its lines,
# authorized on the operator account of every host and on the installer
# ISO's root. Empty means no host authorizes anyone — a fleet in that
# state builds an ISO that boots unreachable, and a `deploy` onto a
# fresh host locks the operator out. Untracked means the same thing to
# the eval, which cannot see an untracked file.
#
# A warning by default (a fleet mid-bootstrap legitimately has none
# until its first `identity` secret is provisioned, which writes it),
# an error under --strict.

keys_dir="$(nh_worktree_keys_dir)" || exit 2
root="$(nh_fleet_root)" || exit 2
strict="${NIXHOLD_LINT_STRICT:-0}"
worst=0
problems=0

report() {
  problems=$((problems + 1))
  if [ "$strict" = "1" ]; then
    echo "VIOLATION: $1"
    worst=3
  else
    echo "WARNING: $1"
  fi
}

login="$keys_dir/login.pub"
if ! nh_pubkey_lines "$login" >/dev/null 2>&1; then
  report "$login is missing or holds no key line — no host authorizes anyone and the installer ISO would boot unreachable (provision the fleet identity with 'nixhold secret edit <host> identity', which writes it, or add your own ssh pubkey line)"
elif git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 &&
  ! git -C "$root" ls-files --error-unmatch -- "$login" >/dev/null 2>&1; then
  report "${login#"$root"/} is not tracked by git — nix eval cannot see an untracked file, so every host authorizes nobody ('git add' it)"
fi

if [ "$problems" -eq 0 ]; then
  echo "OK: keys/login.pub authorizes $(nh_pubkey_lines "$login" | grep -c .) key(s)"
fi
exit "$worst"
