# nixhold secret edit [<host>] [<name>]
#
# Provision-or-edit, decided by whether the ciphertext exists:
#   missing  -> generator set: run it, encrypt its stdout (an sshKey
#                              secret first asks generate-or-paste on
#                              a terminal; paste is the editor path)
#               template set:  prefill $EDITOR with it, encrypt what's saved
#               neither:       open an empty $EDITOR, encrypt what's saved
#   present  -> decrypt with the operator's seat, open $EDITOR,
#               re-encrypt to the fleet's recipient set
#
# Arguments. Two of them are `<host> <name>`. ONE is whichever it
# matches: a host name opens that host's walk, anything else is taken
# as a SECRET name and resolved across the fleet — a fleet-scoped
# secret is `secrets/<name>.age` and needs no host at all, a
# host-scoped one declared on exactly one host resolves to that host,
# and one declared on several opens a picker. None opens the host
# picker.
#
# The walk (no name) prints the plan exactly as `secret list` renders
# it before the first editor opens — once $EDITOR owns the screen the
# buffer name <host>.<name> in its titlebar is the only identification
# left. It prompts only for **required and missing** secrets; an
# optional one is listed with the command that would provision it, and
# never opens an editor unasked — most of a fleet's secrets are
# optional (`identity`, `env`, every repository's), and prompting for
# each would make provisioning one a chore of skipping the rest. The
# named form works for anything declared, optional included. When
# nothing is required-missing, the existing secrets are offered to edit.
#
# Scope decides WHERE, and only where: a host secret is
# `secrets/<host>/<name>.age`, a fleet secret the single
# `secrets/<name>.age`. Both are encrypted to the same set — every
# operator recipient line plus keys/fleet.pub — so nothing here
# computes a per-host recipient list, and adding a host rekeys nothing.
#
# Idempotent: existing ciphertexts are never re-provisioned. The
# framework-declared `identity` secret — fleet-scoped, one key for
# every host — is also the fleet's login key when nothing else is
# authorized: writing it fills in keys/login.pub if that file is
# missing or empty. Every file written is staged the moment it lands
# (an untracked file is invisible to the dirty-flake eval that must
# read it next) and committed at the end.
#
# The required-secret walk `deploy` and `host install` run before a
# build lives here too (nh_provision_required_secrets).

# The grouped plan is `secret list`'s renderer.
# shellcheck source=secret-list.sh
. "$NIXHOLD_LIB_ROOT/secret-list.sh"

cmd_secret_edit() {
  local host="" name="" resolved
  if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    cat <<'EOF'
Usage: nixhold secret edit [<host>] [<name>]

  <host> <name>   that secret on that host.
  one argument    a host name opens its walk; anything else is a
                  secret name, resolved across the fleet.
  no argument     pick a host.
EOF
    return 0
  fi
  nh_require_cmd age jq nix

  if [ -n "${2:-}" ]; then
    host="$1"
    name="$2"
  elif [ -n "${1:-}" ]; then
    if nh_host_platform "$1" >/dev/null 2>&1; then
      host="$1"
    else
      resolved="$(nh_secret_resolve_name "$1")" || return 1
      host="${resolved%%$'\t'*}"
      name="$1"
    fi
  else
    if ! nh_tty; then
      nh_err "expected: nixhold secret edit <host> [<name>]"
      return 1
    fi
    host="$(nh_pick_host "Secrets of which host?")" || return 1
  fi

  local platform sdir json
  platform="$(nh_host_platform "$host")" || {
    nh_err "host '$host' is not in this fleet — 'nixhold status --fleet' lists the roster"
    return 1
  }
  sdir="$(nh_worktree_secrets_dir)" || return 2
  json="$(nh_host_secrets "$host" "$platform")" || return 2

  if [ -n "$name" ]; then
    if ! printf '%s' "$json" | jq -e --arg n "$name" 'has($n)' >/dev/null 2>&1; then
      nh_err "secret '$name' is not declared on $host (add nixhold.secrets.$name first)"
      return 1
    fi
    if [ -e "$(nh_secret_file "$sdir" "$host" "$name" "$(nh_secret_scope "$json" "$name")")" ]; then
      nh_secret_edit_one "$host" "$json" "$sdir" "$name"
    else
      nh_secret_provision "$host" "$json" "$sdir" "$name"
    fi
    return $?
  fi

  # The plan first, in `secret list`'s grouping: it is the same
  # question ("what does this host want, and what has it got"), and
  # the walk below is exactly what its status column says.
  nh_secret_list_host "$host" "$platform" || return $?
  echo

  local required_missing=() optional=() present=() n req scope
  while IFS=$'\t' read -r n scope req; do
    [ -n "$n" ] || continue
    if [ -e "$(nh_secret_file "$sdir" "$host" "$n" "$scope")" ]; then
      present+=("$n")
    elif [ "$req" = "true" ]; then
      required_missing+=("$n")
    else
      optional+=("$n")
    fi
  done < <(printf '%s' "$json" | jq -r '
    to_entries | sort_by(.key)[]
    | [ .key, (.value.scope // "host"), (.value.required | tostring) ] | @tsv')

  local rc=0
  if [ "${#required_missing[@]}" -gt 0 ]; then
    nh_secret_provision "$host" "$json" "$sdir" "${required_missing[@]}" || rc=$?
  fi
  # Optional ones are named, never opened: the command that would
  # provision one is the whole prompt.
  for n in "${optional[@]:-}"; do
    [ -n "$n" ] || continue
    nh_info "optional, not provisioned: $n — provision with 'nixhold secret edit $host $n'"
  done
  [ "$rc" -eq 0 ] || return "$rc"
  [ "${#required_missing[@]}" -eq 0 ] || return 0

  if [ "${#present[@]}" -eq 0 ]; then
    nh_info "nothing required is missing on $host"
    return 0
  fi
  if ! nh_tty; then
    nh_info "nothing required is missing on $host — name a secret to edit it: nixhold secret edit $host <name>"
    return 0
  fi
  nh_info "nothing required is missing on $host"
  name="$(gum choose --header "Edit which secret on $host?" "${present[@]}")" || return 1
  nh_secret_edit_one "$host" "$json" "$sdir" "$name"
}

# nh_secret_resolve_name <name> — which host to edit <name> through,
# as "<host>\t<scope>" on stdout. A fleet-scoped secret has ONE
# ciphertext, so any declarer is the same file and the first is taken.
# A host-scoped one is a file per host: exactly one declarer resolves,
# several open a picker (and, with nobody to ask, are listed rather
# than guessed at).
nh_secret_resolve_name() {
  local name="$1" rows fleet hosts count
  rows="$(nh_secret_declarers "$name")" || true
  if [ -z "$rows" ]; then
    nh_err "'$name' is neither a host in this fleet nor a secret any host declares — 'nixhold secret list' shows the inventory"
    return 1
  fi
  fleet="$(printf '%s\n' "$rows" | awk -F'\t' '$2 == "fleet" { print $1; exit }')"
  if [ -n "$fleet" ]; then
    printf '%s\tfleet' "$fleet"
    return 0
  fi
  hosts="$(printf '%s\n' "$rows" | awk -F'\t' 'NF { print $1 }' | sort -u)"
  count="$(printf '%s\n' "$hosts" | grep -c .)"
  if [ "$count" -eq 1 ]; then
    printf '%s\thost' "$hosts"
    return 0
  fi
  if ! nh_tty; then
    nh_err "'$name' is declared on several hosts ($(printf '%s' "$hosts" | paste -sd' ' -)) and each has its own ciphertext — name the host: nixhold secret edit <host> $name"
    return 1
  fi
  local pick
  # shellcheck disable=SC2086 # host names, split on purpose
  pick="$(gum choose --header "'$name' on which host?" $hosts)" || return 1
  [ -n "$pick" ] || return 1
  printf '%s\thost' "$pick"
}

# nh_secret_provision <host> <secrets-json> <secrets-dir> <name…> —
# encrypt each named secret for the first time. Exit codes: 0 every
# secret provisioned or skipped on purpose, 1 at least one failed.
#
# errexit is IGNORED inside the per-secret subshell: it is the
# condition of an `if`, which disables -e for the whole subshell (and
# this function is itself run as `… || …` by host add / deploy). Every
# step whose failure must abort that secret is checked explicitly.
# Exit codes out of the subshell: 0 provisioned, 2 skipped (nothing to
# encrypt), anything else failed.
nh_secret_provision() {
  local host="$1" json="$2" sdir="$3"
  shift 3
  local total="$#" plan name root keys_dir
  plan="$(printf '%s, ' "$@")"
  nh_info "$total secret(s) to provision on $host: ${plan%, }"
  root="$(nh_fleet_root)" || return 1
  keys_dir="$(nh_worktree_keys_dir 2>/dev/null)" || keys_dir=""

  # Warm the recipient probes and settle the fleet key HERE: each
  # per-secret subshell below inherits the memo but cannot write it
  # back, so a lazy probe would re-run those nix evals once per secret
  # — and a fleet key minted inside a subshell would be minted again by
  # the next one.
  nh_probe_recipient_inputs
  nh_fleet_key_ensure || return 1

  # Iterated over "$@", not a here-string-fed `read` loop: a redirect
  # on the loop would hand $EDITOR (and the gate prompt) a stdin that
  # is not the operator's terminal.
  local added=0 failed=0 rc idx=0 target scope generator template desc sshkey choice
  local written=()
  for name in "$@"; do
    idx=$((idx + 1))
    scope="$(nh_secret_scope "$json" "$name")"
    target="$(nh_secret_file "$sdir" "$host" "$name" "$scope")"
    # Provisioning is for a secret that has NO ciphertext: `age -R -o`
    # truncates whatever sits at the target, so an existing one is
    # never walked into. The realistic case is fleet scope — one
    # ciphertext for the whole fleet, so every host after the first
    # that declares it finds it already there, and the walk must be a
    # no-op rather than an overwrite.
    if [ -e "$target" ]; then
      nh_info "[$idx/$total] $name already provisioned at $target — left as it is (edit it with 'nixhold secret edit $host $name')"
      continue
    fi
    generator="$(printf '%s' "$json" | jq -r --arg n "$name" '.[$n].generator // ""')"
    template="$(printf '%s' "$json" | jq -r --arg n "$name" '.[$n].template // ""')"
    desc="$(printf '%s' "$json" | jq -r --arg n "$name" '.[$n].description // ""')"
    sshkey="$(printf '%s' "$json" | jq -r --arg n "$name" '.[$n].sshKey // false')"
    nh_info "[$idx/$total] $name${desc:+ — $desc}"
    # An SSH key may already exist and be registered elsewhere:
    # offer to adopt it rather than mint a replacement. Pasting is
    # the editor path; Esc skips the secret.
    if [ -n "$generator" ] && [ "$sshkey" = "true" ] && nh_tty; then
      choice="$(nh_prompt_choose "$host/$name is an SSH key:" \
        "generate a new ed25519 key" "paste an existing private key")" || choice=""
      case "$choice" in
        generate*) ;;
        paste*) generator="" ;;
        *)
          nh_warn "no choice for $name — skipping"
          continue
          ;;
      esac
    fi
    if [ -n "$generator" ]; then
      nh_info "  running its generator (no editor; it may prompt)"
    else
      nh_info "  opening $(nh_editor_cmd) — save content to encrypt, save EMPTY to skip"
    fi

    rc=0
    (
      set -euo pipefail
      # One 0700 dir per secret so the buffer can carry an identifying
      # name (<host>.<name>, what the editor shows) without publishing
      # it in a world-readable /tmp listing. Under the process scratch
      # root, not a bare mktemp: a trap installed in this subshell does
      # not run on Ctrl-C (bash resets trapped signals inside one), and
      # the buffer holds the generated key material in plaintext. The
      # dispatcher's handler wipes the root on every exit path.
      workdir="$(nh_tmpdir secret)" || exit 1
      rfile="$workdir/recipients"
      # Attr names are normally filename-safe; sanitized anyway so a
      # quoted name cannot escape the workdir.
      safe="$host.$name"
      safe="${safe//[^A-Za-z0-9._-]/_}"
      tmp="$workdir/$safe"
      : >"$tmp"
      chmod 600 "$tmp"

      nh_recipients_file "$rfile" || exit 1
      if [ -n "$generator" ]; then
        # The generator is operator-declared config; run it in this
        # already-isolated subshell rather than spawning an external
        # interpreter (bash may not be on the CLI's runtime PATH).
        { eval "$generator"; } >"$tmp" || {
          nh_err "generator for $name failed — nothing encrypted"
          exit 1
        }
      else
        # The buffer is encrypted byte-for-byte (ssh keys, hashes,
        # tokens): NEVER prefill instructions into it, since stripping
        # them back out would mangle content that legitimately starts
        # with a comment marker. Identity lives in the filename and the
        # header above, never in the buffer. A template is content, so
        # it is prefilled.
        if [ -n "$template" ]; then
          printf '%s' "$template" >"$tmp"
        fi
        if nh_prompt_gate "edit $host/$name"; then
          nh_run_editor "$tmp" || exit 1
        else
          # Declining at the gate and saving an empty buffer are one
          # path: truncate and fall into the empty check below.
          : >"$tmp"
        fi
      fi
      if [ ! -s "$tmp" ]; then
        nh_warn "empty content for $name — skipping"
        exit 2
      fi
      mkdir -p "$(dirname "$target")" || exit 1
      # Re-checked with the plaintext in hand: the editor (or the
      # generator's prompt) can have taken minutes, and a fleet
      # ciphertext provisioned meanwhile — from another terminal, or by
      # the same walk on another host — must not be truncated here.
      if [ -e "$target" ]; then
        nh_warn "$target appeared while $name was being written — NOT overwritten (edit it with 'nixhold secret edit $host $name')"
        exit 2
      fi
      if ! age -R "$rfile" -o "$target" "$tmp"; then
        rm -f "$target"
        nh_err "encryption of $target failed"
        exit 1
      fi
      nh_ok "encrypted $target"
      nh_stage_for_eval "$root" "$target"
      # The framework declares `identity` on every host and nothing
      # else mints an outbound key: on a fleet that authorizes nobody
      # yet, its pubkey becomes keys/login.pub.
      if [ "$name" = "identity" ]; then
        nh_login_pub_default_from_identity "$tmp" || true
      fi
    ) || rc=$?
    case "$rc" in
      0)
        added=$((added + 1))
        written+=("$target")
        ;;
      2) ;; # skipped on purpose (empty content), already warned
      *) failed=1 ;;
    esac
  done

  if [ "$added" -gt 0 ]; then
    nh_ok "provisioned $added secret(s) on $host"
    local header
    header="secrets($host): provision $(printf '%s ' "${written[@]##*/}" | sed 's/\.age / /g; s/ $//')"
    # The fleet's commit hook caps a header at 60 characters, so a batch
    # whose names overflow it commits as a count instead.
    [ "${#header}" -le 60 ] || header="secrets($host): provision $added secret(s)"
    local commit=("${written[@]}")
    [ -z "$keys_dir" ] || commit+=("$keys_dir/login.pub" "$keys_dir/fleet.key.age" "$keys_dir/fleet.pub")
    nh_commit_paths "$root" "$header" "${commit[@]}"
  elif [ "$failed" -eq 0 ]; then
    nh_info "nothing provisioned on $host ($total skipped)"
  fi
  if [ "$failed" -ne 0 ]; then
    nh_err "some secrets on $host were NOT provisioned — fix the errors above and re-run"
    return 1
  fi
}

# nh_secret_edit_one <host> <secrets-json> <secrets-dir> <name> —
# decrypt, edit, re-encrypt one existing secret.
#
# Checked explicitly rather than through errexit: -e is ignored in a
# subshell whose exit code the caller tests.
nh_secret_edit_one() {
  local host="$1" json="$2" sdir="$3" name="$4" target scope
  scope="$(nh_secret_scope "$json" "$name")"
  target="$(nh_secret_file "$sdir" "$host" "$name" "$scope")"
  (
    set -euo pipefail
    # One 0700 dir so the buffer can carry an identifying name
    # (<host>.<name>, what the editor shows) without publishing it in a
    # world-readable /tmp listing. It lives under the process scratch
    # root: bash resets trapped signals inside this subshell, so a trap
    # here would NOT run on Ctrl-C and would leave the decrypted secret
    # behind — the dispatcher's handler does run, on EXIT/INT/TERM/HUP
    # alike.
    workdir="$(nh_tmpdir secret)" || exit 2
    rfile="$workdir/recipients"
    safe="$host.$name"
    safe="${safe//[^A-Za-z0-9._-]/_}"
    tmp="$workdir/$safe"
    : >"$tmp"
    chmod 600 "$tmp"

    nh_recipients_file "$rfile" || exit 1
    nh_age_decrypt "$target" "$tmp" || exit 1
    # The plaintext is encrypted back byte-for-byte, so nothing is ever
    # prefilled into the buffer: identity lives in its filename.
    nh_info "opening $(nh_editor_cmd) for $host/$name"
    nh_run_editor "$tmp" || exit 1
    # Encrypt to a sibling temp + rename so an age failure can't
    # leave the committed ciphertext truncated.
    age -R "$rfile" -o "$target.tmp" "$tmp" || {
      rm -f "$target.tmp"
      nh_err "re-encryption failed — $target is untouched"
      exit 1
    }
    mv "$target.tmp" "$target" || {
      rm -f "$target.tmp"
      nh_err "could not replace $target — it is untouched"
      exit 1
    }
    nh_ok "updated $target"
    local paths=("$target")
    if [ "$name" = "identity" ]; then
      nh_login_pub_default_from_identity "$tmp" || true
      local login
      if login="$(nh_login_pub_file 2>/dev/null)"; then
        paths+=("$login")
      fi
    fi
    nh_commit_paths "$(nh_fleet_root)" "secrets($host): update $name" "${paths[@]}"
    nh_info "next: nixhold deploy $host"
  )
}

# nh_missing_secrets <host> <platform> [required-only] — the declared
# secrets with no ciphertext in the worktree, one per line. Non-zero
# only when the host can't be probed at all (an absent ciphertext is
# data, not an error).
nh_missing_secrets() {
  local host="$1" platform="$2" required="${3:-0}" sdir json name scope
  sdir="$(nh_worktree_secrets_dir)" || return 1
  json="$(nh_host_secrets "$host" "$platform" 2>/dev/null)" || return 1
  while IFS=$'\t' read -r name scope; do
    [ -n "$name" ] || continue
    [ -e "$(nh_secret_file "$sdir" "$host" "$name" "$scope")" ] || printf '%s\n' "$name"
  done < <(printf '%s' "$json" | jq -r --argjson req "$required" \
    'to_entries[] | select($req == 0 or .value.required)
     | [ .key, (.value.scope // "host") ] | @tsv')
}

# nh_provision_required_secrets <host> <platform> — what `deploy` and
# `host install` run before a build: provision every `required`
# secret that has no ciphertext yet. Interactive (it can open
# $EDITOR), so callers run it with the operator's terminal on stdin
# AND stdout/stderr.
nh_provision_required_secrets() {
  local host="$1" platform="$2" missing
  missing="$(nh_missing_secrets "$host" "$platform" 1)" || return 0
  [ -n "$missing" ] || return 0
  nh_warn "required secrets missing on $host — provisioning them first"
  # shellcheck disable=SC2086 # names are attr names, split on purpose
  nh_secret_provision "$host" "$(nh_host_secrets "$host" "$platform")" \
    "$(nh_worktree_secrets_dir)" $missing
}

# nh_provision_missing_secrets <host> — the walk `host add` ends on.
#
# It provisions the required-missing secrets AND the fleet's
# `identity` key. `identity` is `required = false` — a host must stay
# evaluable before the fleet has one — yet minting it is part of
# registering the FIRST machine rather than of running a service: it
# is the key the operator registers on every forge the fleet's
# repositories name (so the forge list is printed with it), it is what
# the installer ISO clones with, and on a fleet that authorizes nobody
# yet its pubkey becomes keys/login.pub. `password` needs no special
# case: it is `required` on NixOS, so the required set already carries
# it.
#
# Both are fleet-scoped, so this only ever fires on the first host
# that declares them: the loop skips every secret whose ciphertext is
# already in the worktree, and a later `host add` finds them there and
# rekeys nothing — every host reads them with the one fleet key.
#
# Everything else optional — `env`, every repository's env — is named
# with the command that provisions it and never opens an editor here:
# those are fleet-wide, provisioned once from any host, and a
# registration that turned into a dozen editors to skip would be a
# worse walk.
nh_provision_missing_secrets() {
  local host="$1" platform json sdir wanted=() optional=() n scope required rc=0
  platform="$(nh_host_platform "$host")" || return 1
  json="$(nh_host_secrets "$host" "$platform")" || return 1
  sdir="$(nh_worktree_secrets_dir)" || return 1
  while IFS=$'\t' read -r n scope required; do
    [ -n "$n" ] || continue
    [ -e "$(nh_secret_file "$sdir" "$host" "$n" "$scope")" ] && continue
    # The literal `identity` is a framework declaration, so the CLI
    # may name it — the rule that names never carry behaviour is about
    # operator-chosen names.
    if [ "$required" = "true" ] || [ "$n" = "identity" ]; then
      wanted+=("$n")
    else
      optional+=("$n")
    fi
  done < <(printf '%s' "$json" | jq -r '
    to_entries | sort_by(.key)[]
    | [ .key, (.value.scope // "host"), (.value.required | tostring) ] | @tsv')

  if [ "${#wanted[@]}" -gt 0 ]; then
    nh_secret_provision "$host" "$json" "$sdir" "${wanted[@]}" || rc=$?
    # The key is only useful once it is registered where it is used;
    # the fleet already knows which forges those are.
    case " ${wanted[*]} " in
      *" identity "*) nh_announce_forges ;;
    esac
  fi
  for n in "${optional[@]:-}"; do
    [ -n "$n" ] || continue
    nh_info "optional, not provisioned: $n — provision with 'nixhold secret edit $host $n'"
  done
  return "$rc"
}

# nh_announce_forges — after the fleet mints its `identity` key, name
# the forges its declared repositories reach over ssh, so the operator
# knows where the pubkey the generator just printed has to be
# registered. It is also what the installer ISO clones the fleet repo
# with, so registering it is not optional on a fleet that builds one.
# The key is fleet-scoped, so the forges are read from EVERY host's
# `nixhold.repositories`, not just the one being added: registering it
# once covers the fleet. Same two URL shapes the repositories module
# derives its matchBlocks from (scp-like and ssh://); an https URL
# authenticates some other way and is left out. Best-effort: a fleet
# with no repositories prints nothing, and a host that does not
# evaluate is skipped.
nh_announce_forges() {
  local line h platform repos forges all=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    h="${line%% *}"
    platform="${line##* }"
    repos="$(nh_host_eval "$h" "$platform" nixhold.repositories 2>/dev/null)" || continue
    forges="$(printf '%s' "$repos" | jq -r '
      .[].url
      | (capture("^ssh://(?<u>[^@/]+@)?(?<h>[^/:]+)").h // empty)
      // (if test("^[A-Za-z][A-Za-z0-9+.-]*://") then empty
          else (capture("^([^@/:]+@)?(?<h>[^/:]+):").h // empty) end)' 2>/dev/null)" || continue
    all="$all$forges"$'\n'
  done < <(nh_hosts)
  forges="$(printf '%s' "$all" | grep -v '^[[:space:]]*$' | sort -u | paste -sd, - | sed 's/,/, /g')"
  [ -n "$forges" ] || return 0
  nh_info "register the identity pubkey above on: $forges (it is the one key the fleet uses for every declared repository, and what the installer ISO clones with)"
}
