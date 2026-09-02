#!/usr/bin/env bash
# nixhold — single-entrypoint CLI for nixhold-managed fleets.
#
# All subcommands are sourced (not exec'd) so they share the
# helper-lib state and the operator's TTY. The runtime is shipped
# as a `writeShellApplication`; `runtimeInputs` already places
# gum, nix, jq, ssh, etc. on PATH.
set -euo pipefail

# Resolve where this script lives so sourced subcommands can be
# located regardless of cwd. Inside the writeShellApplication
# wrapper, BASH_SOURCE[0] points at the unwrapped script path.
NIXHOLD_LIB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export NIXHOLD_LIB_ROOT

# Every CLI nix call needs flakes — but a fresh machine (vanilla Nix,
# pre-first-switch) hasn't enabled them yet. `extra-` merges harmlessly
# where they're already on; a caller-set NIX_CONFIG is preserved.
NIX_CONFIG="${NIX_CONFIG:+$NIX_CONFIG
}extra-experimental-features = nix-command flakes"
export NIX_CONFIG

# shellcheck source=lib/run.sh
. "$NIXHOLD_LIB_ROOT/lib/run.sh"
# shellcheck source=lib/prompt.sh
. "$NIXHOLD_LIB_ROOT/lib/prompt.sh"
# shellcheck source=lib/ssh.sh
. "$NIXHOLD_LIB_ROOT/lib/ssh.sh"
# shellcheck source=lib/secrets.sh
. "$NIXHOLD_LIB_ROOT/lib/secrets.sh"
# shellcheck source=lib/escrow.sh
. "$NIXHOLD_LIB_ROOT/lib/escrow.sh"

# One process-wide exit path: wipes the scratch root (host keys, the
# repo deploy key, unwrapped identities) and runs whatever rollback a
# verb registered with nh_at_exit. Signals run it too, so a Ctrl-C
# mid-rotation is rolled back rather than left half-applied.
trap nh_run_at_exit EXIT
trap 'nh_run_at_exit; exit 130' INT
trap 'nh_run_at_exit; exit 143' TERM

usage() {
  cat <<'EOF'
nixhold — manage a nixhold-declared fleet.

Bootstrap:
  init                              Provision the operator age identity.
  iso [--flash <device>]            Build (and write) the fleet installer image.

Hosts:
  host add <name> [--install <u@h>] Register a host (and optionally install).
  host install [<name>] [--remote …] Install or re-image a host (picker on the ISO).
  host rotate-key <name> [--remote …] Rotate host SSH+age key, rekey, install it.
  host escrow <name> [--remote …]   Re-escrow a host's LIVE /etc/ssh key.
  host install-key <name> [--remote …] Install the committed host key on the machine.
  host remove <name>                Delete host from the fleet.

Daily:
  deploy <name> [--mode …]          Build + activate a host's config.
  update [--yes]                    Pull, update inputs, review, deploy.
  status [--host …] [--fleet]       Show declared services / secrets / expose.
  logs <host> <service>             Tail journald for a service on a host.

Secrets:
  secret bootstrap <host> [name]    Provision declared-but-missing secrets.
  secret edit <host> <name>         Edit an existing secret.
  secret rekey                      Re-encrypt all secrets to current recipients.

Scaffolding:
  service new <name>                Scaffold a service module.
  profile new <name>                Scaffold a profile.

Quality:
  lint [--strict]                   Convention + invariant checks.
EOF
}

# Two-token verbs ("host add", "secret edit", …) get joined into
# one subcommand-script name so the dispatcher stays flat.
main() {
  if [ "$#" -eq 0 ]; then
    usage
    exit 0
  fi

  case "$1" in
    -h | --help | help)
      usage
      exit 0
      ;;
    init)
      shift
      . "$NIXHOLD_LIB_ROOT/init.sh"
      cmd_init "$@"
      ;;
    iso)
      shift
      . "$NIXHOLD_LIB_ROOT/iso.sh"
      cmd_iso "$@"
      ;;
    deploy)
      shift
      . "$NIXHOLD_LIB_ROOT/deploy.sh"
      cmd_deploy "$@"
      ;;
    update)
      shift
      . "$NIXHOLD_LIB_ROOT/update.sh"
      cmd_update "$@"
      ;;
    status)
      shift
      . "$NIXHOLD_LIB_ROOT/status.sh"
      cmd_status "$@"
      ;;
    lint)
      shift
      . "$NIXHOLD_LIB_ROOT/lint.sh"
      cmd_lint "$@"
      ;;
    logs)
      shift
      . "$NIXHOLD_LIB_ROOT/logs.sh"
      cmd_logs "$@"
      ;;
    host)
      shift
      if [ "$#" -eq 0 ]; then
        nh_err "expected 'host <verb>'"
        exit 1
      fi
      sub="$1"
      shift
      case "$sub" in
        add | install | install-key | remove | rotate-key | escrow)
          . "$NIXHOLD_LIB_ROOT/host-$sub.sh"
          cmd_host_"${sub//-/_}" "$@"
          ;;
        *)
          nh_err "unknown 'host' subcommand: $sub"
          exit 1
          ;;
      esac
      ;;
    secret)
      shift
      if [ "$#" -eq 0 ]; then
        nh_err "expected 'secret <verb>'"
        exit 1
      fi
      sub="$1"
      shift
      case "$sub" in
        edit | rekey | bootstrap)
          . "$NIXHOLD_LIB_ROOT/secret-$sub.sh"
          cmd_secret_"${sub}" "$@"
          ;;
        new)
          nh_err "'secret new' was folded into 'secret bootstrap <host> [name]'"
          exit 1
          ;;
        *)
          nh_err "unknown 'secret' subcommand: $sub"
          exit 1
          ;;
      esac
      ;;
    service)
      shift
      if [ "${1:-}" != "new" ]; then
        nh_err "expected 'service new <name>'"
        exit 1
      fi
      shift
      . "$NIXHOLD_LIB_ROOT/service-new.sh"
      cmd_service_new "$@"
      ;;
    profile)
      shift
      if [ "${1:-}" != "new" ]; then
        nh_err "expected 'profile new <name>'"
        exit 1
      fi
      shift
      . "$NIXHOLD_LIB_ROOT/profile-new.sh"
      cmd_profile_new "$@"
      ;;
    *)
      nh_err "unknown command: $1"
      usage
      exit 1
      ;;
  esac
}

main "$@"
