# nixhold deploy [<name>…|--all] [--mode {switch|boot|test}] [--dry-run]
#                                [--target <addr>]
#
# Daily verb. Each host builds its own system from the fleet at HEAD's
# sha on the forge and is activated from the out path (ARCHITECTURE
# "Where a host is built"; lib/system.sh):
#   - No name: this machine (nh_deploy_self); a usage error when it
#     is not a fleet host. --all: every host this machine can
#     activate (every NixOS host, every Android host; a darwin host
#     only when this Mac is it). Naming is the confirmation: no
#     picker, no prompt.
#   - The checkout is refused dirty and HEAD is pushed when the forge
#     is behind it, once, before the first host.
#   - NixOS: `nix build` of the toplevel as the operator, locally or
#     over nh_ssh, then the profile set and switch-to-configuration
#     as root, locally or over nh_ssh_sudo (one password per process).
#   - Darwin: refused remotely (deploy Macs locally); locally the same
#     two steps with nix-darwin's activate.
#   - Android: the plan is built here and the device converged onto
#     it over adb (deploy-android.sh); --mode does not apply.
# Several hosts deploy in order; a failure on one does not abandon
# the rest, and the verb reports the failed set at the end. A guest
# ("Guests") is deployed by deploying its machine: the name resolves
# to the machine, the plan line says so, and --all names machines
# only, their guests coming with them. A guest has no install step, so
# its FIRST deploy is one: the tailnet auth key of a guest with no
# state directory on the machine is re-minted before the build, and the
# first deploy that starts it records the ssh host key it minted as
# keys/hosts/<guest>.pub, as `host install` does for a machine it
# images.
#
# Before the build: required secrets with no ciphertext are
# provisioned, then the host is made to hold the fleet key. That check
# is a `cat /etc/nixhold/fleet.pub` compared with keys/fleet.pub — free
# when they agree, and only when they do not does the verb open
# keys/fleet.key.age (a passphrase prompt, or a touch of the operator's
# FIDO2 token) and install it. No rekey: every host reads every secret
# with that one key, so a host joining the fleet changes no ciphertext.

# The required-secret walk lives in the sibling verb.
# shellcheck source=secret-edit.sh
. "$NIXHOLD_LIB_ROOT/secret-edit.sh"
# shellcheck source=deploy-android.sh
. "$NIXHOLD_LIB_ROOT/deploy-android.sh"

cmd_deploy() {
  local names=() mode="switch" mode_given=0 dry_run=0 target="" all=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --mode) mode="$2"; mode_given=1; shift 2 ;;
      --dry-run) dry_run=1; shift ;;
      --target) target="$2"; shift 2 ;;
      --all) all=1; shift ;;
      -h | --help)
        cat <<'EOF'
Usage: nixhold deploy [<name>…|--all] [--mode {switch|boot|test}] [--dry-run]
                                      [--target <addr>]

  No name deploys this machine; --all every host it can activate.
EOF
        return 0
        ;;
      -*) nh_err "unknown flag: $1"; return 1 ;;
      *) names+=("$1"); shift ;;
    esac
  done
  case "$mode" in switch | boot | test) ;; *) nh_err "unknown mode: $mode"; return 1 ;; esac
  nh_require_cmd nix
  nh_fleet_root >/dev/null || return 1

  if [ "$all" -eq 1 ]; then
    if [ "${#names[@]}" -gt 0 ]; then
      nh_err "--all takes no host names"
      return 1
    fi
    local line
    while IFS= read -r line; do
      [ -n "$line" ] && names+=("$line")
    done < <(nh_deploy_eligible)
    if [ "${#names[@]}" -eq 0 ]; then
      nh_err "no host in the fleet can be deployed from this machine"
      return 1
    fi
  elif [ "${#names[@]}" -eq 0 ]; then
    local self
    self="$(nh_deploy_self)" || {
      nh_err "this machine ($(nh_hostname)) is not a fleet host — nixhold deploy <name>, or --all for every host it can activate"
      return 1
    }
    names=("$self")
  fi
  # A guest's name means its machine; two names that meet on one
  # machine deploy it once.
  local resolved=() n m seen
  for n in "${names[@]}"; do
    m="$(nh_host_machine "$n" 2>/dev/null || true)"
    if [ -n "$m" ]; then
      nh_info "$n is a guest of $m — deploying $m"
      n="$m"
    fi
    seen=0
    for m in "${resolved[@]}"; do
      [ "$m" = "$n" ] && seen=1
    done
    [ "$seen" -eq 1 ] || resolved+=("$n")
  done
  names=("${resolved[@]}")

  if [ -n "$target" ] && [ "${#names[@]}" -ne 1 ]; then
    nh_err "--target applies to exactly one host"
    return 1
  fi
  if [ "$mode_given" -eq 1 ]; then
    local n
    for n in "${names[@]}"; do
      if [ "$(nh_host_platform "$n" 2>/dev/null || true)" = "android" ]; then
        nh_err "--mode does not apply to $n: an Android host is converged, not switched"
        return 1
      fi
    done
  fi

  # A dirty checkout is refused before anything is prompted for or
  # written: a host builds the fleet at a commit. The reference each
  # host builds is taken right before its build (nh_deploy_host),
  # since the secret walk and a guest's minted key commit on the way.
  local sha
  sha="$(nh_fleet_rev "$(nh_fleet_root)")" || return 1
  nh_info "deploy: ${names[*]} @ ${sha:0:12} — mode=$mode$([ "$dry_run" -eq 1 ] && printf ' dry-run')"

  local name failed=()
  for name in "${names[@]}"; do
    [ "${#names[@]}" -eq 1 ] || nh_info "── deploy $name"
    nh_deploy_host "$name" "$mode" "$dry_run" "$target" || failed+=("$name")
  done
  if [ "${#failed[@]}" -gt 0 ]; then
    nh_err "deploy failed: ${failed[*]}"
    return 1
  fi
  [ "${#names[@]}" -eq 1 ] || nh_ok "deployed: ${names[*]}"
}

# nh_deploy_eligible — the hosts this machine can activate, one per
# line: every NixOS host (the target builds its own closure), every
# Android host (this machine builds the plan and drives adb), plus a
# darwin host only when this Mac is it. A guest is not listed: its
# machine is, and the guest comes with it.
nh_deploy_eligible() {
  local self line name platform
  self="$(nh_deploy_self)" || self=""
  while IFS= read -r line; do
    name="${line%% *}"
    platform="${line##* }"
    [ -z "$(nh_host_machine "$name")" ] || continue
    if [ "$platform" = "nixos" ] || [ "$platform" = "android" ] || [ "$name" = "$self" ]; then
      printf '%s\n' "$name"
    fi
  done < <(nh_hosts)
}

# nh_deploy_capture_guest_keys <machine> <local> <target> — after a
# machine activated, record the ssh host pubkey of every guest that
# has none committed yet. The key is minted by sshd inside the guest
# on its first start, under the machine's
# /var/lib/nixos-containers/<guest>/etc/ssh — root-only, hence sudo
# either side — and the container starts after activation returns, so
# the read waits for it a little. A guest whose key cannot be read
# (mode=boot, a container that failed to start) is a warning: `host
# key <guest>` records it later, over the tailnet.
nh_deploy_capture_guest_keys() {
  local machine="$1" local_host="$2" target="$3" root keys_dir guest live path snippet
  root="$(nh_fleet_root)" || return 1
  keys_dir="$(nh_worktree_keys_dir)" || return 1
  local pending=()
  while IFS= read -r guest; do
    [ -n "$guest" ] || continue
    [ -e "$keys_dir/hosts/$guest.pub" ] || pending+=("$guest")
  done < <(nh_host_guests "$machine")
  [ "${#pending[@]}" -gt 0 ] || return 0

  # The password is cached in THIS shell so the reads below, which run
  # in command substitutions, do not each ask for it.
  if [ "$local_host" -ne 1 ]; then
    case "${target%%@*}" in
      root) ;;
      *) nh_sudo_password_ensure "$target" || return 0 ;;
    esac
  fi
  for guest in "${pending[@]}"; do
    path="/var/lib/nixos-containers/$guest/etc/ssh/ssh_host_ed25519_key.pub"
    snippet="i=0; until nh_rsudo test -r $path || [ \$i -ge 6 ]; do i=\$((i+1)); sleep 5; done; nh_rsudo cat $path"
    if [ "$local_host" -eq 1 ]; then
      live="$(sh -c "$(nh_sudo_preamble_local)
$snippet" 2>/dev/null)" || live=""
    else
      live="$(nh_ssh_sudo "$target" --host "$machine" -- "$snippet" </dev/null 2>/dev/null)" || live=""
    fi
    if [ -z "$live" ]; then
      nh_warn "$guest's ssh host key is not readable on $machine yet (the guest has not started?) — 'nixhold host key $guest' records it once the guest is on the tailnet"
      continue
    fi
    nh_commit_host_pub "$guest" "$live" >/dev/null || continue
    nh_ok "$guest's ssh host pubkey is recorded as keys/hosts/$guest.pub"
    nh_commit_paths "$root" "host($guest): pubkey" "$keys_dir/hosts/$guest.pub"
  done
}

# nh_deploy_guest_authkeys <machine> <local> <target> — the guests of
# this machine that have never run, and the tailnet auth key each of
# them needs to join. A guest has no install step, so its first deploy
# IS its install: the node of its name is deleted and a fresh
# single-use key minted and committed before the build (see "The
# tailnet's API client"). A guest whose state directory exists is
# never touched — its node is live, and deleting it would cut the
# machine off from a host that is running.
#
# /var/lib/nixos-containers is 0755, so the probe escalates nothing and
# a routine deploy still prompts for no password. A directory that
# cannot be read at all leaves the guest alone: only a definite "no"
# means never-installed.
nh_deploy_guest_authkeys() {
  local machine="$1" local_host="$2" target="$3" guest snippet out root
  local fresh=() written=() p rc=0
  while IFS= read -r guest; do
    [ -n "$guest" ] || continue
    snippet="test -d /var/lib/nixos-containers/$guest && echo yes || echo no"
    if [ "$local_host" -eq 1 ]; then
      out="$(sh -c "$snippet" 2>/dev/null)" || out=""
    else
      out="$(nh_ssh "$target" --host "$machine" -- "$snippet" </dev/null 2>/dev/null)" || out=""
    fi
    [ "$out" = "no" ] && fresh+=("$guest")
  done < <(nh_host_guests "$machine")
  [ "${#fresh[@]}" -gt 0 ] || return 0

  root="$(nh_fleet_root)" || return 1
  for guest in "${fresh[@]}"; do
    nh_info "$guest has never run on $machine — this deploy is its install: re-minting its tailnet auth key"
    out="$(nh_tailnet_remint "$guest" nixos --delete-node)" || {
      nh_err "could not re-mint $guest's tailnet auth key — it would come up off the tailnet"
      rc=1
      continue
    }
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      written+=("$p")
    done <<<"$out"
  done
  [ "${#written[@]}" -eq 0 ] || nh_commit_paths "$root" "secrets: tailnet keys for ${fresh[*]}" "${written[@]}"
  return "$rc"
}

# nh_deploy_guest_health <machine> <local> <target> — one line per
# guest of the machine, and non-zero when any of them did not come up.
#
# The container unit is Type=simple ("Guests"), so an active unit says
# nspawn was exec'd and nothing about the system inside it: a guest
# that never reached its default target would leave the deploy looking
# clean. `systemctl is-system-running --wait` inside the guest is the
# answer: it blocks until the guest's initial transaction settles, so
# it doubles as the wait, and its word is what the summary carries.
# `running` and `degraded` pass; a degraded guest is one failed unit,
# which `nixhold status <guest>` is the verb for. Anything else is a
# failed deploy, with the guest's own errors printed under it. The
# 120 s cap is the deploy's, not systemd's: `--wait` has none.
#
# The machine transport is what it waits for first. `--machine` reaches
# the guest's bus, which does not exist for the first seconds of a
# guest that activation started moments ago, and `systemctl` says
# "no such file or directory" rather than waiting for it.
nh_deploy_guest_health() {
  local machine="$1" local_host="$2" target="$3" guest word snippet
  local guests=() bad=()
  while IFS= read -r guest; do
    [ -n "$guest" ] && guests+=("$guest")
  done < <(nh_host_guests "$machine")
  [ "${#guests[@]}" -gt 0 ] || return 0

  # Cached in THIS shell, as in nh_deploy_capture_guest_keys: the reads
  # below run in command substitutions and would each ask again.
  if [ "$local_host" -ne 1 ]; then
    case "${target%%@*}" in
      root) ;;
      *) nh_sudo_password_ensure "$target" || return 0 ;;
    esac
  fi

  for guest in "${guests[@]}"; do
    # `exec` so that the timeout's signal reaches systemctl itself once
    # the transport is up, rather than the shell that waited for it.
    snippet="nh_rsudo timeout 120 sh -c 'until systemctl --machine $guest show --property=Version >/dev/null 2>&1; do sleep 2; done; exec systemctl is-system-running --machine $guest --wait'"
    if [ "$local_host" -eq 1 ]; then
      word="$(sh -c "$(nh_sudo_preamble_local)
$snippet" 2>/dev/null)" || true
    else
      word="$(nh_ssh_sudo "$target" --host "$machine" -- "$snippet" </dev/null 2>/dev/null)" || true
    fi
    # `is-system-running` exits non-zero for every word but `running`,
    # and prints nothing at all when timeout killed it or the guest has
    # no bus to ask.
    case "${word:-unreachable}" in
      running | degraded)
        nh_ok "guest $guest: $word"
        ;;
      *)
        bad+=("$guest")
        nh_err "guest $guest: ${word:-unreachable} — it did not finish booting on $machine"
        snippet="nh_rsudo journalctl -M $guest -b -p err -n 20"
        if [ "$local_host" -eq 1 ]; then
          sh -c "$(nh_sudo_preamble_local)
$snippet" 2>&1 || true
        else
          nh_ssh_sudo "$target" --host "$machine" -- "$snippet" </dev/null 2>&1 || true
        fi
        ;;
    esac
  done
  [ "${#bad[@]}" -eq 0 ] || return 1
}

# nh_deploy_host <name> <mode> <dry-run> <target> — one host.
nh_deploy_host() {
  local name="$1" mode="$2" dry_run="$3" target="$4" root platform arch
  root="$(nh_fleet_root)" || return 1
  platform="$(nh_host_platform "$name")" || {
    nh_err "host '$name' is not in this fleet — 'nixhold status --fleet' lists the roster"
    return 1
  }
  arch="$(nh_host_arch "$name")"

  local local_host=0
  if [ "$(nh_deploy_self 2>/dev/null || true)" = "$name" ]; then
    local_host=1
  fi

  # Required secrets with no ciphertext are provisioned first: it can
  # open editors/run generators, and a failure aborts — activation
  # would only fail later with a much worse error.
  nh_provision_required_secrets "$name" "$platform" || {
    nh_err "secret provisioning failed — fix the secrets above, then re-run deploy"
    return 1
  }

  # An Android host holds no fleet key and takes no ssh: nothing
  # below applies. Its plan is built here and applied over adb.
  if [ "$platform" = "android" ]; then
    nh_android_deploy "$name" "$dry_run" "$target"
    return $?
  fi

  # The address is resolved here rather than in the nixos branch below:
  # the fleet-key check travels over the same connection, and a host
  # nothing can reach must fail before the build rather than after it.
  local user addr
  if [ "$platform" = "nixos" ] && [ "$local_host" -ne 1 ]; then
    user="$(nh_host_eval "$name" "$platform" "nixhold.identity.username" | jq -r '.')"
    if [ -z "$target" ]; then
      addr="$(nh_deploy_addr "$name")"
      [ -z "$addr" ] && {
        nh_err "could not resolve deploy address for $name (on the tailnet yet? pass --target <addr>)"
        return 1
      }
      target="${user}@${addr}"
    else
      case "$target" in
        *@*) ;;
        *) target="${user}@${target}" ;;
      esac
    fi
  fi

  # Then the other half of "this host must be able to read what it
  # declares": every secret is encrypted to the ONE fleet key, so the
  # only thing a host needs is that key at /etc/nixhold/fleet.key. The
  # machine's own /etc/nixhold/fleet.pub says which one it holds, so
  # this is a comparison first and an install only on a mismatch —
  # which is what makes a routine deploy prompt for nothing.
  local sync=()
  if [ "$platform" = "nixos" ] && [ "$local_host" -ne 1 ] && [ -n "$target" ]; then
    sync=(--remote "$target" --host "$name")
  fi
  nh_fleet_key_sync "${sync[@]}" || {
    nh_err "$name does not hold the fleet key — it would activate unable to decrypt any secret"
    return 1
  }

  local out ref
  case "$platform" in
    nixos)
      # A guest that has never run joins the tailnet with a key minted
      # here, before the build that creates it.
      [ "$dry_run" -eq 1 ] || nh_deploy_guest_authkeys "$name" "$local_host" "$target" || return 1
      # The reference, after everything this deploy commits: the sha
      # the target builds is the one that holds them, and HEAD is on
      # the forge before the target fetches it.
      ref="$(nh_fleet_ref "$root")" || return 1
      # The build, as the operator: it is the operator's ssh config on
      # the target that names the key the fleet is fetched with, and
      # a build needs no root. Connect as the operator user, not root:
      # the hardened openssh preset is prohibit-password and no root
      # authorized key is planted. The connection is pinned to $name's
      # committed host key (nh_ssh), so a deploy cannot activate a
      # closure on whatever answered at that address.
      nh_info "$name builds ${ref%%\?*} @ ${ref##*rev=}"
      if [ "$local_host" -eq 1 ]; then
        out="$(sh -c "$(nh_build_cmd "$ref" nixos "$name" "$dry_run")")" || return 1
      else
        out="$(nh_ssh "$target" --host "$name" -- "$(nh_build_cmd "$ref" nixos "$name" "$dry_run")" </dev/null)" || return 1
      fi
      [ "$dry_run" -eq 1 ] && return 0
      [ -n "$out" ] || {
        nh_err "the build printed no out path"
        return 1
      }
      # Activation, as root: the one sudo of this process, which the
      # guest-key read and the unit kick below reuse.
      if [ "$local_host" -eq 1 ]; then
        sh -c "$(nh_sudo_preamble_local)
$(nh_activate_nixos_snippet "$out" "$mode")" || return 1
      else
        nh_ssh_sudo "$target" --host "$name" -- "$(nh_activate_nixos_snippet "$out" "$mode")" </dev/null || return 1
      fi
      # The guests this machine started for the first time.
      nh_deploy_capture_guest_keys "$name" "$local_host" "$target"
      # Activation put the closure in place; a unit that gave up
      # before this deploy fixed its cause is restarted, user scope
      # and the system-scope checks alike (a check is meant to run
      # again on every deploy), and then those units say whether the
      # host reached what it declares and whether what it declares
      # works.
      nh_provision_kick "$name" nixos "$local_host" "$target"
      nh_provision_report "$name" nixos "$local_host" "$target"
      # And each guest says whether it booted at all.
      nh_deploy_guest_health "$name" "$local_host" "$target" || return 1
      ;;
    darwin)
      # darwin deploys are always local — so gate on the OS, not on
      # nh_deploy_self, which a fleet of several Macs with a hostname
      # that matches none of them cannot resolve.
      if [ "$(uname -s)" != "Darwin" ]; then
        nh_err "darwin hosts deploy locally only — run this on $name itself"
        return 1
      fi
      if [ "$local_host" -ne 1 ]; then
        nh_warn "local hostname is '$(nh_hostname)', not '$name' — assuming this machine IS $name (darwin deploys are local-only)"
      fi
      if [ "$mode" != switch ]; then
        nh_err "--mode $mode does not apply to a Mac: nix-darwin switches"
        return 1
      fi
      [ -e /run/current-system/activate ] || {
        nh_err "this Mac has never switched — the first activation goes through 'nixhold host install $name'"
        return 1
      }
      ref="$(nh_fleet_ref "$root")" || return 1
      nh_info "$name builds ${ref%%\?*} @ ${ref##*rev=}"
      out="$(sh -c "$(nh_build_cmd "$ref" darwin "$name" "$dry_run")")" || return 1
      [ "$dry_run" -eq 1 ] && return 0
      # nix-darwin activates as root, same as the NixOS path. No kick
      # here: a launchd agent's KeepAlive retries unbounded, so a
      # cause this deploy fixed is picked up within the throttle.
      nh_activate_darwin "$out" || return 1
      # sudo-ok: the checks are launchd daemons and only root is
      # shown the system domain. This verb has just elevated on this
      # terminal, so the read costs no prompt of its own.
      nh_provision_report "$name" darwin 1 "" 1
      ;;
    *)
      nh_err "unsupported arch for $name: $arch"
      return 1
      ;;
  esac
}
