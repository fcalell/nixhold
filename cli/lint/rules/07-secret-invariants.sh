# Rule: per-secret declaration invariants. These mirror the module
# assertions in modules/secrets/default.nix — assertions only fire on
# a toplevel build, which hosts blocked from building (e.g. missing
# facter report) never reach; lint checks the same invariants from a
# plain option eval.
#   - homePath only on operator-owned secrets (owner = "user") — the
#     HM symlink targets the operator's $HOME.
#   - sshKey only on operator-owned secrets.
#   - `unit` never together with homePath/sshKey: systemd reads an
#     EnvironmentFile as root, a home symlink is the operator's.
#   - `unit` only on a NixOS host — there are no systemd units on
#     darwin, so the option would silently do nothing there. This one
#     has no module assertion behind it (the darwin half simply has no
#     `unit` wiring to assert about), which is exactly why lint owns
#     it.

worst=0
while IFS= read -r line; do
  [ -n "$line" ] || continue
  h="${line%% *}"
  platform="${line##* }"
  json="$(nh_host_secrets "$h" "$platform" 2>/dev/null)" || {
    echo "ERROR: could not evaluate nixhold.secrets for $h — secret invariants check skipped"
    [ "$worst" -lt 2 ] && worst=2
    continue
  }

  bad="$(printf '%s' "$json" | jq -r --arg p "$platform" '
    to_entries[]
    | . as $e
    | [
        (select($e.value.homePath != null and $e.value.owner != "user")
          | "\($e.key) — homePath set but owner is not \"user\""),
        (select($e.value.sshKey and $e.value.owner != "user")
          | "\($e.key) — sshKey set but owner is not \"user\""),
        (select($e.value.unit != null and ($e.value.homePath != null or $e.value.sshKey))
          | "\($e.key) — unit is a systemd EnvironmentFile read as root; it cannot also be an operator file in $HOME (homePath/sshKey)"),
        (select($e.value.unit != null and $p != "nixos")
          | "\($e.key) — unit = \"\($e.value.unit)\" on a \($p) host (systemd units are NixOS-only)")
      ][]')"
  if [ -n "$bad" ]; then
    while IFS= read -r msg; do
      [ -n "$msg" ] || continue
      echo "VIOLATION: $h/$msg"
      worst=3
    done <<<"$bad"
  fi
done < <(nh_hosts)

[ "$worst" -eq 0 ] && echo "OK: secret declaration invariants hold"
exit "$worst"
