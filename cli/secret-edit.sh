# nixhold secret edit [<host>] [<name>]
#
# Provision-or-edit, decided by whether the ciphertext exists:
#   missing  -> generator set: run it, encrypt its stdout (no prompt)
#               template set:  prefill $EDITOR with it, encrypt what's saved
#               neither:       open an empty $EDITOR, encrypt what's saved
#   present  -> decrypt with the operator identity, open $EDITOR,
#               re-encrypt to the current recipient set
# No <host>: pick one. No <name>: every missing secret on the host is
# provisioned in one numbered walk — the plan is printed before the
# first editor opens, because once $EDITOR owns the screen the buffer
# name <host>.<name> in its titlebar is the only identification left —
# and when nothing is missing the existing secrets are offered to edit.
# Idempotent: existing ciphertexts are never re-provisioned. Secrets
# with `sshIdentity = true` also get their derived pubkey committed as
# keys/hosts/<host>/identity.pub. Every ciphertext written is staged
# the moment it lands (an untracked file is invisible to the
# dirty-flake eval that must read it next) and committed at the end.
#
# The required-secret walk `deploy` and `host install` run before a
# build lives here too (nh_provision_required_secrets).

cmd_secret_edit() {
  local host="${1:-}" name="${2:-}"
  if [ "$host" = "-h" ] || [ "$host" = "--help" ]; then
    echo "Usage: nixhold secret edit [<host>] [<name>]"
    return 0
  fi
  nh_require_cmd age jq nix

  if [ -z "$host" ]; then
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
  json="$(nh_host_eval "$host" "$platform" nixhold.secrets)" || return 2

  if [ -n "$name" ]; then
    if ! printf '%s' "$json" | jq -e --arg n "$name" 'has($n)' >/dev/null 2>&1; then
      nh_err "secret '$name' is not declared on $host (add nixhold.secrets.$name first)"
      return 1
    fi
    if [ -e "$sdir/hosts/$host/$name.age" ]; then
      nh_secret_edit_one "$host" "$json" "$sdir" "$name"
    else
      nh_secret_provision "$host" "$json" "$sdir" "$name"
    fi
    return $?
  fi

  local missing=() present=() n
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    if [ -e "$sdir/hosts/$host/$n.age" ]; then present+=("$n"); else missing+=("$n"); fi
  done < <(printf '%s' "$json" | jq -r 'keys[]')

  if [ "${#missing[@]}" -gt 0 ]; then
    nh_secret_provision "$host" "$json" "$sdir" "${missing[@]}"
    return $?
  fi
  if [ "${#present[@]}" -eq 0 ]; then
    nh_info "no secrets declared on $host"
    return 0
  fi
  if ! nh_tty; then
    nh_info "every declared secret on $host has a ciphertext — name one to edit it: nixhold secret edit $host <name>"
    return 0
  fi
  nh_info "every declared secret on $host has a ciphertext"
  name="$(gum choose --header "Edit which secret on $host?" "${present[@]}")" || return 1
  nh_secret_edit_one "$host" "$json" "$sdir" "$name"
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

  # Warm the recipient-check probes HERE: each per-secret subshell
  # below inherits the memo but cannot write it back, so probing lazily
  # would re-run those nix evals once per secret.
  nh_probe_recipient_inputs

  # Iterated over "$@", not a here-string-fed `read` loop: a redirect
  # on the loop would hand $EDITOR (and the gate prompt) a stdin that
  # is not the operator's terminal.
  local added=0 failed=0 rc idx=0 target generator template desc written=()
  for name in "$@"; do
    idx=$((idx + 1))
    target="$sdir/hosts/$host/$name.age"
    generator="$(printf '%s' "$json" | jq -r --arg n "$name" '.[$n].generator // ""')"
    template="$(printf '%s' "$json" | jq -r --arg n "$name" '.[$n].template // ""')"
    desc="$(printf '%s' "$json" | jq -r --arg n "$name" '.[$n].description // ""')"
    nh_info "[$idx/$total] $name${desc:+ — $desc}"
    if [ -n "$generator" ]; then
      nh_info "  running its generator — no editor, no prompt"
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

      nh_recipients_file "$json" "$host" "$name" "$rfile" || exit 1
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
      if ! age -R "$rfile" -o "$target" "$tmp"; then
        rm -f "$target"
        nh_err "encryption of $target failed"
        exit 1
      fi
      nh_ok "encrypted $target"
      nh_stage_for_eval "$root" "$target"
      if [ "$(printf '%s' "$json" | jq -r --arg n "$name" '.[$n].sshIdentity // false')" = "true" ]; then
        nh_commit_identity_pub "$host" "$tmp" || true
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
    nh_commit_paths "$root" "secrets: provision $host: $(printf '%s ' "${written[@]##*/}" | sed 's/\.age / /g; s/ $//')" \
      "${written[@]}" ${keys_dir:+"$keys_dir/hosts/$host/identity.pub"}
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
  local host="$1" json="$2" sdir="$3" name="$4" target
  target="$sdir/hosts/$host/$name.age"
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
    idfile="$workdir/identity"
    safe="$host.$name"
    safe="${safe//[^A-Za-z0-9._-]/_}"
    tmp="$workdir/$safe"
    : >"$idfile"
    : >"$tmp"
    chmod 600 "$idfile" "$tmp"

    nh_recipients_file "$json" "$host" "$name" "$rfile" || exit 1
    nh_unwrap_identity "$idfile" || exit 1
    age -d -i "$idfile" -o "$tmp" "$target" || {
      nh_err "could not decrypt $target with the operator identity"
      exit 1
    }
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
    nh_commit_paths "$(nh_fleet_root)" "secrets: update $host/$name" "$target"
    nh_info "next: nixhold deploy $host"
  )
}

# nh_missing_secrets <host> <platform> [required-only] — the declared
# secrets with no ciphertext in the worktree, one per line. Non-zero
# only when the host can't be probed at all (an absent ciphertext is
# data, not an error).
nh_missing_secrets() {
  local host="$1" platform="$2" required="${3:-0}" sdir json name
  sdir="$(nh_worktree_secrets_dir)" || return 1
  json="$(nh_host_eval "$host" "$platform" nixhold.secrets 2>/dev/null)" || return 1
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    [ -e "$sdir/hosts/$host/$name.age" ] || printf '%s\n' "$name"
  done < <(printf '%s' "$json" | jq -r --argjson req "$required" \
    'to_entries[] | select($req == 0 or .value.required) | .key')
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
  nh_secret_provision "$host" "$(nh_host_eval "$host" "$platform" nixhold.secrets)" \
    "$(nh_worktree_secrets_dir)" $missing
}

# nh_provision_missing_secrets <host> — the full walk `host add` runs:
# every declared secret with no ciphertext, required or not.
nh_provision_missing_secrets() {
  local host="$1" platform missing
  platform="$(nh_host_platform "$host")" || return 1
  missing="$(nh_missing_secrets "$host" "$platform")" || return 1
  [ -n "$missing" ] || return 0
  # shellcheck disable=SC2086 # names are attr names, split on purpose
  nh_secret_provision "$host" "$(nh_host_eval "$host" "$platform" nixhold.secrets)" \
    "$(nh_worktree_secrets_dir)" $missing
}
