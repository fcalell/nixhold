# Rule: every keys/networks/<network>.age names a tailscale-typed
# network this fleet declares, and is tracked by git.
#
# The file's PRESENCE is what turns minted auth keys on for the hosts
# of that network (see "The tailnet's API client"), so a name that
# matches nothing is a credential the fleet holds and nothing reads:
# the hosts it was committed for keep asking the operator to paste a
# key, and the reason is a typo or a network renamed out of the roster.
# Untracked is the same silence one commit later, on the next checkout.
#
# What the recipients ARE is not checked: an age ciphertext carries no
# recipient fingerprint, so "encrypted to the operator lines alone" is
# not readable from the file. `nixhold operator check` is the verb that
# answers it, by opening what the fleet holds.

root="$(nh_fleet_root)" || exit 2
worst=0
declared="$(nh_tailnet_networks 2>/dev/null)" || declared=""
found=0

while IFS= read -r net; do
  [ -n "$net" ] || continue
  found=$((found + 1))
  file="$(nh_tailnet_client_file "$net")" || exit 2
  if ! printf '%s\n' "$declared" | grep -qx "$net"; then
    echo "VIOLATION: ${file#"$root"/} names no tailscale-typed network of this fleet (it declares $(printf '%s' "$declared" | paste -sd' ' -)) — no host mints an auth key through it; rename it, or drop it"
    worst=3
    continue
  fi
  if git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 &&
    ! git -C "$root" ls-files --error-unmatch -- "$file" >/dev/null 2>&1; then
    echo "VIOLATION: ${file#"$root"/} is not tracked by git — the next checkout of this fleet mints no auth key for '$net' and every install asks for a pasted one ('git add' it)"
    worst=3
  fi
done < <(nh_tailnet_client_networks)

if [ "$worst" -eq 0 ]; then
  if [ "$found" -eq 0 ]; then
    echo "OK: this fleet commits no tailnet API client; auth keys are pasted from the admin console"
  else
    echo "OK: $found tailnet API client(s), each naming a declared tailscale network"
  fi
fi
exit "$worst"
