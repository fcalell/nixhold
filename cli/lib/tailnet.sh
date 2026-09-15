# The tailnet's API client, and the auth keys it mints.
#
# A headless host joins its tailnet with a pre-auth key. When the
# fleet commits the network's OAuth client at
# `keys/networks/<network>.age` — `client_id` and `client_secret`, one
# KEY=value per line — the CLI mints that key itself instead of asking
# the operator to paste one: single-use, pre-authorized, tagged
# `tag:nixhold`, one hour to live. `host install` and a guest's first
# `deploy` delete the node of that name first, since the name must be
# free (the vhost, the cert and the deploy address all key on it).
#
# That credential mints tailnet access and deletes nodes, and no host
# needs it, so it is encrypted to the operator lines ALONE — the
# second file after keys/fleet.key.age that the fleet key never opens.
#
# Neither the client secret nor the access token ever reaches an argv:
# both travel to curl in 0600 config files (`-K`) under the process
# scratch root, which the dispatcher wipes on every exit path.

# nh_tailnet_client_file <network> -> keys/networks/<network>.age in
# the worktree, existing or not. Non-zero only when keysDir can't be
# resolved.
nh_tailnet_client_file() {
  local keys_dir
  keys_dir="$(nh_worktree_keys_dir)" || return 2
  printf '%s/networks/%s.age' "$keys_dir" "$1"
}

# nh_tailnet_client_networks — the networks this fleet commits a
# client for, one name per line. The filesystem is the witness, as it
# is for the ciphertexts `secret rekey` walks: a client whose network
# was renamed out of the roster is still a file encrypted to the
# operator, and leaving it behind is how a seat change locks one out.
nh_tailnet_client_networks() {
  local keys_dir f
  keys_dir="$(nh_worktree_keys_dir)" || return 2
  [ -d "$keys_dir/networks" ] || return 0
  for f in "$keys_dir"/networks/*.age; do
    [ -f "$f" ] || continue
    f="${f##*/}"
    printf '%s\n' "${f%.age}"
  done
}

# nh_tailnet_networks — the fleet's tailscale-typed network names, one
# per line.
nh_tailnet_networks() {
  nh_fleet_view | jq -r '.network | to_entries[] | select(.value.type == "tailscale") | .key'
}

# nh_tailnet_client_plain <network> -> path of the DECRYPTED client,
# opened over the operator route the first time this CLI process asks
# for it. Mirrors nh_fleet_key_plain: the plaintext lives in the
# $$-keyed scratch root, so a verb that mints for several hosts costs
# one unlock.
nh_tailnet_client_plain() {
  local net="$1" root out src
  root="$(nh_tmp_root)" || return 1
  out="$root/tailnet-client.$net"
  if [ -s "$out" ]; then
    printf '%s' "$out"
    return 0
  fi
  src="$(nh_tailnet_client_file "$net")" || return 2
  if [ ! -f "$src" ]; then
    nh_err "no API client for the '$net' tailnet at $src — 'nixhold secret edit network/$net' commits one"
    return 1
  fi
  if ! (umask 077 && : >"$out"); then
    nh_err "could not create $out"
    return 1
  fi
  if ! nh_age_decrypt "$src" "$out"; then
    rm -f "$out"
    nh_err "$src was not opened by the operator's seat — it is encrypted to the operator lines alone, so plug in the token or run from a checkout that holds keys/operator.age"
    return 1
  fi
  chmod 0600 "$out" || return 1
  printf '%s' "$out"
}

# nh_tailnet_client_field <plaintext-file> <key> — the value of one
# KEY=value line. `=` is a separator once: a secret may contain more.
nh_tailnet_client_field() {
  awk -v k="$2" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' "$1"
}

# nh_tailnet_token <network> -> path of a 0600 curl config (`-K`)
# whose one line is the `Authorization: Bearer` header for the
# network's tailnet. The TOKEN itself is never printed and never
# passed as an argument; callers hand the path to curl. Memoized per
# network: the token lives an hour and one verb may mint for several
# hosts.
nh_tailnet_token() {
  local net="$1" root out plain cfg id secret resp token
  nh_require_cmd curl jq || return 1
  root="$(nh_tmp_root)" || return 1
  out="$root/tailnet-auth.$net"
  if [ -s "$out" ]; then
    printf '%s' "$out"
    return 0
  fi
  plain="$(nh_tailnet_client_plain "$net")" || return $?
  id="$(nh_tailnet_client_field "$plain" client_id)"
  secret="$(nh_tailnet_client_field "$plain" client_secret)"
  if [ -z "$id" ] || [ -z "$secret" ]; then
    nh_err "the '$net' API client names no client_id / client_secret — 'nixhold secret edit network/$net' expects one KEY=value per line"
    return 1
  fi
  # The whole request body in the config file, so neither half of the
  # credential shows up in `ps`.
  cfg="$root/tailnet-token.$net.conf"
  if ! (
    umask 077
    {
      printf 'url = "https://api.tailscale.com/api/v2/oauth/token"\n'
      printf 'data-urlencode = "grant_type=client_credentials"\n'
      printf 'data-urlencode = "client_id=%s"\n' "$id"
      printf 'data-urlencode = "client_secret=%s"\n' "$secret"
    } >"$cfg"
  ); then
    nh_err "could not stage the token request for '$net'"
    return 1
  fi
  resp="$(curl -fsS -K "$cfg")" || {
    rm -f "$cfg"
    nh_err "the '$net' tailnet refused the API client's credentials — check keys/networks/$net.age against the admin console's OAuth clients page"
    return 1
  }
  rm -f "$cfg"
  token="$(printf '%s' "$resp" | jq -r '.access_token // empty')"
  if [ -z "$token" ]; then
    nh_err "the '$net' token endpoint returned no access_token"
    return 1
  fi
  if ! (umask 077 && printf 'header = "Authorization: Bearer %s"\n' "$token" >"$out"); then
    nh_err "could not stage the '$net' access token"
    return 1
  fi
  printf '%s' "$out"
}

# nh_tailnet_mint_key <network> <host> — one auth key on stdout.
# Single-use and NOT ephemeral (an ephemeral node disappears the
# moment it goes offline), pre-authorized so the join needs no console
# click, tagged because a key an OAuth client mints must carry tags,
# and an hour to live because its whole life is the install.
nh_tailnet_mint_key() {
  local net="$1" host="$2" auth body resp key
  auth="$(nh_tailnet_token "$net")" || return $?
  body="$(jq -nc --arg d "nixhold $host" '{
    capabilities: { devices: { create: {
      reusable: false,
      ephemeral: false,
      preauthorized: true,
      tags: [ "tag:nixhold" ]
    } } },
    expirySeconds: 3600,
    description: $d
  }')" || return 1
  resp="$(curl -fsS -K "$auth" -H 'Content-Type: application/json' \
    --data-raw "$body" "https://api.tailscale.com/api/v2/tailnet/-/keys")" || {
    nh_err "the '$net' tailnet minted no auth key for $host — the OAuth client needs the auth_keys scope and the tag:nixhold tag, and the tailnet policy needs the matching tagOwners line"
    return 1
  }
  key="$(printf '%s' "$resp" | jq -r '.key // empty')"
  if [ -z "$key" ]; then
    nh_err "the '$net' key endpoint returned no key for $host"
    return 1
  fi
  printf '%s' "$key"
}

# nh_tailnet_device_ids <devices-json> <hostname> — the node ids of
# every device whose machine name is EXACTLY <hostname>, one per line.
# Exact, never a prefix: the tailnet dedupes a repeated name by
# suffixing it (`homelab-1`), and those are other machines.
nh_tailnet_device_ids() {
  printf '%s' "$1" | jq -r --arg h "$2" '.devices[]? | select(.hostname == $h) | .nodeId'
}

# nh_tailnet_delete_node <network> <hostname> — delete every node of
# that name. Finding none is not an error: the name being free is the
# point, and a first install starts that way.
nh_tailnet_delete_node() {
  local net="$1" name="$2" auth devices id n=0
  auth="$(nh_tailnet_token "$net")" || return $?
  devices="$(curl -fsS -K "$auth" "https://api.tailscale.com/api/v2/tailnet/-/devices")" || {
    nh_err "could not list the '$net' tailnet's devices"
    return 1
  }
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    curl -fsS -K "$auth" -X DELETE "https://api.tailscale.com/api/v2/device/$id" >/dev/null || {
      nh_err "could not delete the '$net' node $name ($id) — remove it in the admin console, then re-run"
      return 1
    }
    n=$((n + 1))
    nh_ok "deleted the '$net' node $name ($id)"
  done < <(nh_tailnet_device_ids "$devices" "$name")
  [ "$n" -gt 0 ] || nh_info "no '$net' node named $name — nothing to delete"
}

# nh_tailnet_write_key <network> <host> <target> — mint one key and
# write it as <target>, encrypted to the NORMAL recipient set (the
# operator lines plus keys/fleet.pub) like any secret: the host reads
# it at activation with the fleet key. The path is printed on stdout
# for the caller to commit; every message is on stderr.
#
# Encrypt to a sibling temp + rename, so a failure cannot leave a
# host's committed key truncated.
nh_tailnet_write_key() {
  local net="$1" host="$2" target="$3" workdir rfile key
  workdir="$(nh_tmpdir tailnet)" || return 1
  rfile="$workdir/recipients"
  nh_recipients_file "$rfile" || return 1
  key="$(nh_tailnet_mint_key "$net" "$host")" || return 1
  if ! (umask 077 && printf '%s\n' "$key" >"$workdir/key"); then
    nh_err "could not stage the minted key for $host"
    return 1
  fi
  mkdir -p "$(dirname "$target")" || return 1
  if ! age -R "$rfile" -o "$target.tmp" "$workdir/key"; then
    rm -f "$target.tmp" "$workdir/key"
    nh_err "could not encrypt the minted auth key to $target"
    return 1
  fi
  if ! mv "$target.tmp" "$target"; then
    rm -f "$target.tmp" "$workdir/key"
    nh_err "could not write $target"
    return 1
  fi
  rm -f "$workdir/key"
  nh_ok "minted a single-use '$net' auth key for $host and wrote $target"
  nh_stage_for_eval "$(nh_fleet_root)" "$target"
  printf '%s\n' "$target"
}

# nh_tailnet_remint <host> <platform> [--delete-node] — re-mint every
# `tailscaleAuthKey` secret the host declares, printing the ciphertext
# paths written. A no-op (exit 0, no output) when the host declares
# none or when the fleet commits no client for the network named: the
# key is then the operator's to paste, which `secret edit` walks.
#
# --delete-node frees the tailnet name first, once per host. It is
# what `host install` and a guest's first deploy pass: the machine is
# about to be wiped or created, so the live node of that name is the
# stale one.
nh_tailnet_remint() {
  local host="$1" platform="$2" delete="${3:-}" json rows sdir
  local name scope net target deleted=0 rc=0
  json="$(nh_host_secrets "$host" "$platform" 2>/dev/null)" || return 0
  rows="$(printf '%s' "$json" | jq -r '
    to_entries[] | select(.value.tailscaleAuthKey != null)
    | [ .key, (.value.scope // "host"), .value.tailscaleAuthKey ] | @tsv')"
  [ -n "$rows" ] || return 0
  sdir="$(nh_worktree_secrets_dir)" || return 2
  while IFS=$'\t' read -r name scope net; do
    [ -n "$name" ] || continue
    [ -f "$(nh_tailnet_client_file "$net")" ] || continue
    if [ "$delete" = "--delete-node" ] && [ "$deleted" -eq 0 ]; then
      nh_tailnet_delete_node "$net" "$host" || return 1
      deleted=1
    fi
    target="$(nh_secret_file "$sdir" "$host" "$name" "$scope")"
    nh_tailnet_write_key "$net" "$host" "$target" || rc=1
  done <<<"$rows"
  return "$rc"
}

# ---------------------------------------------------------------------
# The client file as a `secret edit` / `secret show` argument.

# nh_tailnet_client_arg <argument> — the network name when the
# argument is the `network/<name>` form and <name> is a
# tailscale-typed network of this fleet, non-zero otherwise. Both
# verbs resolve their lone argument through this before asking
# nh_secret_resolve_name: the client is a key file, not a secret, and
# it has no host.
nh_tailnet_client_arg() {
  local arg="$1" net
  case "$arg" in
    network/*) net="${arg#network/}" ;;
    *) return 1 ;;
  esac
  if [ -z "$net" ] || ! nh_tailnet_networks | grep -qx "$net"; then
    nh_err "'$net' is not a tailscale-typed network of this fleet — it declares $(nh_tailnet_networks | paste -sd' ' -)"
    return 2
  fi
  printf '%s' "$net"
}

# nh_tailnet_client_edit <network> — provision-or-edit the API client,
# encrypted to the operator lines ALONE (nh_operator_recipient_file,
# the same set keys/fleet.key.age is written to). Missing: the editor
# opens on the KEY=value scaffold the console's two fields go into.
#
# Checked explicitly rather than through errexit: -e is ignored in a
# subshell whose exit code the caller tests.
nh_tailnet_client_edit() {
  local net="$1" target rcpt
  target="$(nh_tailnet_client_file "$net")" || return 2
  rcpt="$(nh_operator_recipient_file)" || return 1
  nh_age_require_encrypt || return 1
  (
    set -euo pipefail
    # Under the process scratch root, not a bare mktemp: bash resets
    # trapped signals inside a subshell, so a trap here would NOT run
    # on Ctrl-C and would leave the credential in plaintext.
    workdir="$(nh_tmpdir tailnet-client)" || exit 1
    tmp="$workdir/network.$net"
    : >"$tmp"
    chmod 600 "$tmp"
    if [ -e "$target" ]; then
      nh_age_decrypt "$target" "$tmp" || exit 1
      nh_info "opening $(nh_editor_cmd) for the '$net' API client"
    else
      printf 'client_id=\nclient_secret=\n' >"$tmp"
      nh_info "the '$net' tailnet has no API client yet — create one at login.tailscale.com/admin/settings/oauth with the auth_keys and devices:core scopes and the tag:nixhold tag, then paste its id and secret"
    fi
    nh_run_editor "$tmp" || exit 1
    if ! grep -q '^client_secret=.' "$tmp"; then
      nh_warn "no client_secret in the buffer — the '$net' API client was NOT written"
      exit 2
    fi
    mkdir -p "$(dirname "$target")" || exit 1
    age -R "$rcpt" -o "$target.tmp" "$tmp" || {
      rm -f "$target.tmp"
      nh_err "encryption failed — $target is untouched"
      exit 1
    }
    mv "$target.tmp" "$target" || {
      rm -f "$target.tmp"
      nh_err "could not replace $target — it is untouched"
      exit 1
    }
    chmod 0644 "$target"
    nh_ok "wrote $target — auth keys for hosts on '$net' are minted from now on"
    nh_stage_for_eval "$(nh_fleet_root)" "$target"
    nh_commit_paths "$(nh_fleet_root)" "keys($net): API client" "$target"
  )
}

# nh_tailnet_client_show <network> — the client's plaintext on stdout,
# nothing written and nothing staged, as `secret show` is for a secret.
nh_tailnet_client_show() {
  local net="$1" target workdir
  target="$(nh_tailnet_client_file "$net")" || return 2
  if [ ! -e "$target" ]; then
    nh_err "no API client at $target — commit one with 'nixhold secret edit network/$net'"
    return 1
  fi
  workdir="$(nh_tmpdir tailnet-client)" || return 1
  nh_age_decrypt "$target" "$workdir/plain" || return 1
  cat "$workdir/plain"
  rm -f "$workdir/plain"
}
