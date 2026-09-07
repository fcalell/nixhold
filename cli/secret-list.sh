# nixhold secret list [<host>] [--fleet]
#
# Two views of the same declarations.
#
# No <host>: the fleet INVENTORY — one row per ciphertext, whoever
# declares it:
#
#   name  scope  hosts  status  category  description
#
# `hosts` is the host the ciphertext belongs to (host scope) or the
# hosts that declare it (fleet scope, "all" when that is the whole
# roster). Below the rows, the keys: which fleet key the repo names,
# how many login keys it authorizes, which hosts have a recorded
# pubkey, and which operator routes exist.
#
# <host>: that host's own view — every secret it declares, grouped by
# the category its declarer set (framework / services / repositories /
# operator), with the status column. There is no recipients column:
# every ciphertext in the fleet carries exactly the operator lines plus
# keys/fleet.pub, so "who can read this" has one answer fleet-wide.
#
# Status is `provisioned` (the ciphertext is in the worktree),
# `missing (required)` — the only state that blocks a build — or
# `optional`, which is a standing invitation, not a defect.
#
# Declaration-side like `status`: no host is contacted. `--fleet`
# walks every host in the roster, host view each.

cmd_secret_list() {
  local host="" fleet=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --fleet)
        fleet=1
        shift
        ;;
      -h | --help)
        cat <<'EOF'
Usage: nixhold secret list [<host>] [--fleet]

  No host   the fleet inventory: every ciphertext, who declares it,
            and the state of the fleet's keys.
  <host>    that host's declared secrets, grouped by category.
  --fleet   the host view for every host in the roster.
EOF
        return 0
        ;;
      -*)
        nh_err "unknown flag: $1"
        return 1
        ;;
      *)
        if [ -z "$host" ]; then
          host="$1"
          shift
        else
          nh_err "extra arg: $1"
          return 1
        fi
        ;;
    esac
  done
  nh_require_cmd jq nix

  if [ "$fleet" -eq 1 ]; then
    [ -z "$host" ] || nh_warn "--fleet ignores the host argument ($host)"
    local line rc=0 first=1
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      [ "$first" -eq 1 ] || echo
      first=0
      nh_secret_list_host "${line%% *}" "${line##* }" || rc=1
    done < <(nh_hosts)
    return "$rc"
  fi

  if [ -z "$host" ]; then
    nh_secret_list_inventory
    return $?
  fi
  nh_secret_list_host "$host"
}

# nh_secret_list_inventory — the fleet view. Every host's declarations
# are read once and folded into one row per ciphertext; the keys
# section then says what those ciphertexts are encrypted to and who can
# log in. A host that does not evaluate is named and the walk goes on —
# one broken host must not hide the fleet — but the verb's exit status
# remembers it.
nh_secret_list_inventory() {
  local sdir rc=0 host platform json total=0 line
  sdir="$(nh_worktree_secrets_dir)" || return 2

  # <name>\t<scope>\t<host>\t<required>\t<category>\t<description>, one
  # line per declaration; folded into rows below.
  local decls=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    host="${line%% *}"
    platform="${line##* }"
    total=$((total + 1))
    if ! json="$(nh_host_secrets "$host" "$platform" 2>/dev/null)"; then
      nh_warn "$host does not evaluate — its secrets are missing from this inventory"
      rc=1
      continue
    fi
    decls="$decls$(printf '%s' "$json" | jq -r --arg h "$host" '
      to_entries[]
      | [ .key, (.value.scope // "host"), $h,
          (.value.required | tostring),
          (.value.category // "operator"),
          ((.value.description // "") | gsub("\t"; " ")) ]
      | @tsv')
"
  done < <(nh_hosts)

  printf '%-22s %-6s %-22s %-18s %-12s %s\n' SECRET SCOPE HOSTS STATUS CATEGORY DESCRIPTION
  local name scope hosts req category desc target status found=0
  while IFS=$'\t' read -r name scope hosts req category desc; do
    [ -n "$name" ] || continue
    found=1
    target="$(nh_secret_file "$sdir" "${hosts%%,*}" "$name" "$scope")"
    if [ -e "$target" ]; then
      status="provisioned"
    elif [ "$req" = "true" ]; then
      status="missing (required)"
    else
      status="optional"
    fi
    # A fleet secret declared by every host is "all": naming a roster
    # back to the operator who wrote it is noise.
    if [ "$scope" = "fleet" ] && [ "$(printf '%s' "$hosts" | tr ',' '\n' | grep -c .)" = "$total" ]; then
      hosts="all ($total)"
    fi
    printf '%-22s %-6s %-22s %-18s %-12s %s\n' "$name" "$scope" "$hosts" "$status" "$category" "$desc"
  done < <(printf '%s' "$decls" | nh_secret_inventory_rows)
  [ "$found" -eq 1 ] || printf '  no secret declared anywhere in the fleet\n'

  echo
  nh_secret_list_keys || rc=1
  return "$rc"
}

# nh_secret_inventory_rows — declaration lines on stdin (name, scope,
# host, required, category, description), one row per CIPHERTEXT out.
# A fleet-scoped name collapses to one row whose host column lists
# every declarer; a host-scoped one stays one row per host, because
# that is one file per host on disk. `required` is true when any
# declarer requires it — the strictest declaration is the one that
# blocks a build.
nh_secret_inventory_rows() {
  awk -F'\t' '
    {
      name = $1; scope = $2; host = $3; req = $4; cat = $5; desc = $6
      key = (scope == "fleet") ? name SUBSEP "fleet" : name SUBSEP host
      if (!(key in seen)) {
        seen[key] = 1
        order[++n] = key
        rname[key] = name; rscope[key] = scope
        rhosts[key] = host; rreq[key] = req
        rcat[key] = cat; rdesc[key] = desc
      } else {
        rhosts[key] = rhosts[key] "," host
        if (req == "true") rreq[key] = "true"
        if (rdesc[key] == "") rdesc[key] = desc
      }
    }
    END {
      for (i = 1; i <= n; i++) {
        k = order[i]
        printf "%s\t%s\t%s\t%s\t%s\t%s\n", rname[k], rscope[k], rhosts[k], rreq[k], rcat[k], rdesc[k]
      }
    }
  ' | sort -t"$(printf '\t')" -k1,1 -k3,3
}

# nh_secret_list_keys — the other half of the inventory: what the
# ciphertexts above are encrypted to, and who the fleet lets in. Read
# from the committed files only — nothing is decrypted, no token is
# touched, no machine is contacted.
nh_secret_list_keys() {
  local keys_dir fleet_pub fleet_key line n rc=0 host
  keys_dir="$(nh_worktree_keys_dir)" || return 1
  fleet_pub="$keys_dir/fleet.pub"
  fleet_key="$keys_dir/fleet.key.age"

  printf 'keys\n'
  if line="$(nh_pubkey_line "$fleet_pub")" && [ -f "$fleet_key" ]; then
    printf '  %-16s %s\n' "fleet key" "$line"
  elif [ -f "$fleet_key" ]; then
    printf '  %-16s %s\n' "fleet key" "$fleet_key exists but fleet.pub names no recipient"
    rc=1
  elif [ -e "$fleet_pub" ]; then
    printf '  %-16s %s\n' "fleet key" "fleet.pub names a key but fleet.key.age is missing"
    rc=1
  else
    printf '  %-16s %s\n' "fleet key" "none — 'nixhold secret rekey' mints it"
    rc=1
  fi

  n="$(nh_pubkey_lines "$keys_dir/login.pub" 2>/dev/null | grep -c . || true)"
  if [ "${n:-0}" -gt 0 ]; then
    printf '  %-16s %s\n' "login keys" "$n in keys/login.pub"
  else
    printf '  %-16s %s\n' "login keys" "none — no host authorizes anyone and the ISO boots unreachable"
  fi

  local have=() missing=()
  while IFS= read -r host; do
    [ -n "$host" ] || continue
    if [ -e "$keys_dir/hosts/$host.pub" ]; then
      have+=("$host")
    else
      missing+=("$host")
    fi
  done < <(nh_all_hosts)
  printf '  %-16s %s\n' "host pubkeys" \
    "${#have[@]} recorded${have[0]+ (${have[*]})}${missing[0]+, missing for ${missing[*]}}"

  nh_probe_recipient_inputs
  local routes=()
  nh_age_has_token_recipient && routes+=("FIDO2 token recipient")
  nh_age_wrapped_identity >/dev/null && routes+=("passphrase identity")
  if [ "${#routes[@]}" -eq 0 ]; then
    printf '  %-16s %s\n' "operator" "NO route — nothing in this checkout can decrypt anything"
    rc=1
  else
    printf '  %-16s %s\n' "operator" "$(printf '%s, ' "${routes[@]}" | sed 's/, $//')"
  fi
  return "$rc"
}

# nh_secret_list_host <host> [platform] — the grouped table for one
# host. Also the plan `secret edit` prints before its first editor
# opens, so the operator sees the same shape in both verbs.
nh_secret_list_host() {
  local host="$1" platform="${2:-}" json sdir
  if [ -z "$platform" ]; then
    platform="$(nh_host_platform "$host")" || {
      nh_err "host '$host' is not in this fleet — 'nixhold status --fleet' lists the roster"
      return 1
    }
  fi
  sdir="$(nh_worktree_secrets_dir)" || return 2
  if ! json="$(nh_host_secrets "$host" "$platform")"; then
    nh_err "host '$host' ($platform) does not evaluate — see the error above"
    return 1
  fi

  printf '%s (%s)\n' "$host" "$platform"
  local category label found=0
  # Fixed order: the framework's own first, then what the host's
  # services and repositories brought, then whatever the operator
  # declared directly.
  for category in framework service repository operator; do
    case "$category" in
      framework) label="framework" ;;
      service) label="services" ;;
      repository) label="repositories" ;;
      operator) label="operator" ;;
    esac
    local rows
    rows="$(printf '%s' "$json" | jq -r --arg c "$category" '
      to_entries
      | map(select((.value.category // "operator") == $c))
      | sort_by(.key)[]
      | [ .key, (.value.scope // "host"),
          (if .value.required then "required" else "optional" end),
          (.value.description // "") ]
      | @tsv')"
    [ -n "$rows" ] || continue
    found=1
    printf '  %s\n' "$label"
    local name scope req desc target status
    while IFS=$'\t' read -r name scope req desc; do
      [ -n "$name" ] || continue
      target="$(nh_secret_file "$sdir" "$host" "$name" "$scope")"
      if [ -e "$target" ]; then
        status="provisioned"
      elif [ "$req" = "required" ]; then
        status="missing (required)"
      else
        status="optional"
      fi
      printf '    %-22s %-6s %-18s %s\n' "$name" "$scope" "$status" "$desc"
    done <<<"$rows"
  done
  [ "$found" -eq 1 ] || printf '  no secrets declared\n'
}
