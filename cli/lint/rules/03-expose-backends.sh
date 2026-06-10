# Rule 5: every expose.<name>.backend references a port in the
# same service's network.ports.

root="$(nh_fleet_root)" || exit 2
nixos_hosts="$(nix eval --json --no-warn-dirty "$root#nixosConfigurations" --apply 'builtins.attrNames' 2>/dev/null | jq -r '.[]?' || true)"

worst=0
for h in $nixos_hosts; do
  services="$(nh_host_eval "$h" nixos nixhold.services 2>/dev/null)" || {
    echo "ERROR: could not evaluate nixhold.services for $h — backend check skipped"
    [ "$worst" -lt 2 ] && worst=2
    continue
  }
  refs="$(echo "$services" | jq -r '
    to_entries[]
    | .key as $svc
    | (.value.expose // {} | to_entries[])
    | "\($svc)\t\(.key)\t\(.value.backend)"
  ' 2>/dev/null || true)"
  [ -z "$refs" ] && continue
  while IFS=$'\t' read -r svc ep backend; do
    [ -z "$svc" ] && continue
    has="$(echo "$services" | jq -r --arg s "$svc" --arg b "$backend" \
      '.[$s].network.ports[$b] // empty')"
    if [ -z "$has" ]; then
      echo "VIOLATION: $h/$svc/expose.$ep references unknown backend port '$backend'"
      worst=3
    fi
  done <<<"$refs"
done

[ "$worst" -eq 0 ] && echo "OK: every expose backend resolves"
exit "$worst"
