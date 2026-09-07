# Rule: the keys every ciphertext in this fleet is encrypted to.
#
# There is exactly one recipient set — every line of keys/operator.pub
# plus the line in keys/fleet.pub — so this rule checks the two files
# that define it rather than walking per-host recipient lists.
#
#   operator   keys/operator.pub (layout.ageRecipient) is TRACKED by
#              git and names at least one recipient, and at least one
#              route back in exists: a FIDO2 token recipient
#              (age1fido2-hmac1…), or the passphrase-wrapped identity
#              file. Recipients with no route is a fleet encrypting to
#              a key nobody holds. Untracked is its own failure: an
#              untracked file is invisible to dirty-flake eval, so the
#              module's recipient list silently drops it and every
#              secret written afterwards locks that seat out.
#
#   fleet key  keys/fleet.pub and keys/fleet.key.age exist TOGETHER and
#              are tracked. One without the other is an error, not a
#              warning: a pub with no ciphertext names a private key
#              nobody holds (every host would decrypt nothing), and a
#              ciphertext with no pub means nothing can be encrypted
#              for the hosts at all.
#
# Checked from the committed files only — lint never asks for a
# passphrase and never talks to the token, so an unplugged token still
# counts as a route.

root="$(nh_fleet_root)" || exit 2
keys_dir="$(nh_worktree_keys_dir)" || exit 2
worst=0

is_tracked() {
  git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  git -C "$root" ls-files --error-unmatch -- "$1" >/dev/null 2>&1
}

nh_probe_recipient_inputs
if [ -z "$_NH_OP_RECIPIENT_FILE" ]; then
  echo "ERROR: nixhold.layout.ageRecipient could not be probed — the operator recipient check was skipped"
  worst=2
elif [ -z "$_NH_OP_RECIPIENT_KEYS" ]; then
  echo "VIOLATION: $_NH_OP_RECIPIENT_FILE holds no recipient — nothing can be encrypted to the operator ('nixhold host add' generates a passphrase identity; a FIDO2 token's age1fido2-hmac1… recipient goes in the same file, one per line)"
  worst=3
else
  if ! is_tracked "$_NH_OP_RECIPIENT_FILE"; then
    echo "VIOLATION: ${_NH_OP_RECIPIENT_FILE#"$root"/} is not tracked by git — nix eval cannot see an untracked file, so the operator would silently drop out of every recipient set ('git add' it)"
    worst=3
  fi
  if ! nh_age_has_token_recipient && ! nh_age_wrapped_identity >/dev/null; then
    echo "VIOLATION: $_NH_OP_RECIPIENT_FILE names recipients but this fleet has no way back in — no FIDO2 token recipient (age1fido2-hmac1…) and no wrapped identity at nixhold.layout.ageIdentityWrapped; every ciphertext here is encrypted to a key this checkout cannot use"
    worst=3
  fi
fi

fleet_pub="$keys_dir/fleet.pub"
fleet_key="$keys_dir/fleet.key.age"
if [ -e "$fleet_pub" ] && [ ! -e "$fleet_key" ]; then
  echo "VIOLATION: $fleet_pub exists but $fleet_key does not — the fleet names a key nobody holds; restore the ciphertext, or 'nixhold secret rotate' to mint a new pair while the operator can still open the secrets"
  worst=3
elif [ -e "$fleet_key" ] && [ ! -e "$fleet_pub" ]; then
  echo "VIOLATION: $fleet_key exists but $fleet_pub does not — nothing can be encrypted for the hosts; restore the recipient line (it is 'age-keygen -y' on the decrypted fleet key)"
  worst=3
elif [ ! -e "$fleet_key" ]; then
  echo "VIOLATION: this fleet has no fleet key ($fleet_key) — no host can decrypt anything; 'nixhold secret rekey' mints it and re-encrypts every secret to it"
  worst=3
else
  for f in "$fleet_pub" "$fleet_key"; do
    if ! is_tracked "$f"; then
      echo "VIOLATION: ${f#"$root"/} is not tracked by git — an untracked recipient is invisible to eval, and an uncommitted fleet key is not in the repo ('git add' it)"
      worst=3
    fi
  done
fi

[ "$worst" -eq 0 ] && echo "OK: the operator recipients and the fleet key are committed and reachable"
exit "$worst"
