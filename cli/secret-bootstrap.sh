# nixhold secret bootstrap <host> [name]
#
# Walks the host's declared secrets (`nixhold.secrets`) — or just
# <name> when given — and provisions any whose ciphertext is missing:
#   - generator set      -> run it, capture stdout, encrypt (non-interactive)
#   - template set        -> prefill $EDITOR with it, encrypt what's saved
#   - neither             -> open an empty $EDITOR, encrypt what's saved
# The pending set is computed before the first editor opens: once
# $EDITOR owns the screen the announced plan is gone, so each step is
# numbered and its buffer is named <host>.<name> — the editor's
# titlebar is the only identification left in front of the operator.
# Idempotent: existing .age files are skipped. Secrets with
# `sshIdentity = true` additionally get their derived pubkey
# committed as keys/hosts/<host>/identity.pub.

cmd_secret_bootstrap() {
  local host="${1:-}" only="${2:-}"
  if [ -z "$host" ]; then
    nh_err "expected: nixhold secret bootstrap <host> [name]"
    return 1
  fi
  nh_require_cmd age jq nix

  local platform sdir json names
  platform="$(nh_host_platform "$host")" || {
    nh_err "host '$host' not found in fleet"
    return 1
  }
  sdir="$(nh_worktree_secrets_dir)" || return 2
  json="$(nh_host_eval "$host" "$platform" nixhold.secrets)" || return 2
  if [ -n "$only" ]; then
    if ! printf '%s' "$json" | jq -e --arg n "$only" 'has($n)' >/dev/null 2>&1; then
      nh_err "secret '$only' is not declared on $host (add nixhold.secrets.$only first)"
      return 1
    fi
    if [ -e "$sdir/hosts/$host/$only.age" ]; then
      nh_err "$sdir/hosts/$host/$only.age already exists — use 'secret edit'"
      return 1
    fi
    names="$only"
  else
    names="$(printf '%s' "$json" | jq -r 'keys[]')"
  fi
  if [ -z "$names" ]; then
    nh_info "no secrets declared on $host"
    return 0
  fi

  # Partition before provisioning anything: the plan has to be on
  # screen while the operator can still read it.
  local pending=() plan="" name
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if [ -e "$sdir/hosts/$host/$name.age" ]; then
      nh_info "skip $name (exists)"
    else
      pending+=("$name")
      plan="${plan:+$plan, }$name"
    fi
  done <<<"$names"
  local total="${#pending[@]}"
  if [ "$total" -eq 0 ]; then
    nh_info "nothing to bootstrap on $host (all present)"
    return 0
  fi
  nh_info "$total secret(s) to provision on $host: $plan"

  # Iterated as an array, not a here-string-fed `read` loop: a redirect
  # on the loop would hand $EDITOR (and the gate prompt) a stdin that
  # is not the operator's terminal.
  #
  # errexit is IGNORED inside the per-secret subshell below: it is the
  # condition of an `if`, which disables -e for the whole subshell (and
  # this verb is itself run as `cmd_secret_bootstrap … || …` by host
  # add / deploy). Every step whose failure must abort that secret is
  # checked explicitly. Exit codes out of the subshell: 0 provisioned,
  # 2 skipped (nothing to encrypt), anything else failed.
  local added=0 failed=0 rc idx=0 target generator template desc
  for name in "${pending[@]}"; do
    idx=$((idx + 1))
    target="$sdir/hosts/$host/$name.age"
    generator="$(printf '%s' "$json" | jq -r --arg n "$name" '.[$n].generator // ""')"
    template="$(printf '%s' "$json" | jq -r --arg n "$name" '.[$n].template // ""')"
    desc="$(printf '%s' "$json" | jq -r --arg n "$name" '.[$n].description // ""')"
    nh_info "[$idx/$total] $name${desc:+ — $desc}"
    if [ -n "$generator" ]; then
      nh_info "  running its generator — no editor, no prompt"
    else
      nh_info "  opening ${EDITOR:-vi} — save content to encrypt, save EMPTY to skip"
    fi

    rc=0
    (
      set -euo pipefail
      # One 0700 dir per secret so the buffer can carry an identifying
      # name (<host>.<name>, what the editor shows) without publishing
      # it in a world-readable /tmp listing.
      workdir="$(mktemp -d -t nixhold-secret.XXXXXX)" || exit 1
      chmod 700 "$workdir"
      trap 'rm -rf "$workdir"' EXIT
      rfile="$workdir/recipients"
      # Attr names are normally filename-safe; sanitized anyway so a
      # quoted name cannot escape the workdir.
      safe="$host.$name"
      safe="${safe//[^A-Za-z0-9._-]/_}"
      tmp="$workdir/$safe"
      : >"$tmp"
      chmod 600 "$tmp"

      nh_recipients_file "$json" "$name" "$rfile" || exit 1
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
          "${EDITOR:-vi}" "$tmp"
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
      if [ "$(printf '%s' "$json" | jq -r --arg n "$name" '.[$n].sshIdentity // false')" = "true" ]; then
        nh_commit_identity_pub "$host" "$tmp" || true
      fi
    ) || rc=$?
    case "$rc" in
      0) added=$((added + 1)) ;;
      2) ;; # skipped on purpose (empty content), already warned
      *) failed=1 ;;
    esac
  done

  if [ "$added" -gt 0 ]; then
    nh_ok "bootstrapped $added secret(s) on $host"
    nh_info "review + commit: git -C \"$(nh_fleet_root)\" add and commit $sdir/hosts/$host"
  elif [ "$failed" -eq 0 ]; then
    nh_info "nothing bootstrapped on $host ($total skipped)"
  fi
  if [ "$failed" -ne 0 ]; then
    nh_err "some secrets on $host were NOT provisioned — fix the errors above and re-run"
    return 1
  fi
}

# nh_bootstrap_if_missing <host> <platform> — used by `deploy` to
# auto-walk bootstrap when a required secret has no ciphertext yet.
nh_bootstrap_if_missing() {
  local host="$1" platform="$2" sdir json any=0 name
  sdir="$(nh_worktree_secrets_dir)" || return 0
  json="$(nh_host_eval "$host" "$platform" nixhold.secrets 2>/dev/null)" || return 0
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    [ -e "$sdir/hosts/$host/$name.age" ] || any=1
  done < <(printf '%s' "$json" | jq -r 'to_entries[] | select(.value.required) | .key')
  if [ "$any" -eq 1 ]; then
    nh_warn "required secrets missing on $host — running bootstrap first"
    cmd_secret_bootstrap "$host"
  fi
}
