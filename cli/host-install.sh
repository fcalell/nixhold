# nixhold host install [<name>] [--remote <user>@<ip>] [--disk <by-id>]
#                               [--yes]
#
# Two entry points, one phase sequence:
#   --remote  drive the install over SSH from any fleet machine
#             (nixos-anywhere with --build-on-remote: the target
#             builds its own closure).
#   no flag   install THIS machine in place. Allowed only inside the
#             installer environment, marked by the plain file
#             /etc/nixhold-installer that the ISO drops — so a running
#             fleet machine can never be reformatted by accident.
#             There is no hostname auto-detection; the marker is the
#             whole guard. ($NIXHOLD_INSTALLER_MARKER overrides the
#             path — test hook only, never set in production.)
#
# No <name> opens the host picker: every host this machine can
# install (NixOS hosts; a darwin host only on that Mac) as a reformat
# candidate, plus "new host…", which hands off to `host add` — whose
# own last step is the install question. Off the ISO a picked NixOS
# host is then asked for the address of its booted installer. Darwin
# hosts dispatch from arch and always run locally (see
# nh_darwin_install); the ISO is NixOS-only.
#
# Host key: cache first, else the committed escrow (see lib/escrow.sh)
# — so a reformat driven from a machine that never ran `host add` for
# this host still lands a key agenix can decrypt with. An install that
# used a cached key with no escrow backfills the escrow.
#
# Disk: the roster field `hosts.<name>.disk`, written by the picker
# (or --disk); the framework renders its one disko shape from it. A
# host that declares `disko.devices` in its own module is never asked
# — install formats what that names. The facter report lands at
# `nixhold.hardware.facterReport` (default `<hostsDir>/<name>/facter.json`).
#
# NOTE: the live install paths cannot be exercised in CI; the
# deterministic parts (disk enumeration/rendering, roster rewrite,
# key staging, command construction) are.

# The dispatcher sources lib/ only; the required-secret walk lives in
# a sibling verb.
# shellcheck source=secret-edit.sh
. "$NIXHOLD_LIB_ROOT/secret-edit.sh"

# nh_installer_env and nh_sudo live in lib/run.sh: the clone and
# deploy-key paths need them before any verb is sourced.

# nh_target_sh <remote> <sh-snippet> — run a snippet on the install
# target: locally when installing this machine, over ssh in --remote
# mode. Keeps disk enumeration and by-id resolution single-sourced.
#
# No --host: in --remote mode the machine answering is the installer
# ISO, whose host key is generated fresh on every boot, so the fleet's
# committed key for <name> is NOT what it presents and there is nothing
# to pin to. These snippets read block devices; the host key itself
# never travels over them (it goes through nixos-anywhere's
# --extra-files, below).
nh_target_sh() {
  local remote="$1" script="$2"
  if [ -z "$remote" ]; then
    sh -c "$script"
  else
    nh_ssh "$remote" -- "$script"
  fi
}

# nh_set_host_disk <hosts-file> <name> <by-id> — write `disk = "…";`
# into <name>'s roster entry: in place when the entry already has one,
# else as its last field. The entry is found the way `host remove`
# finds it (opening line to the closing `};` at the same indentation).
nh_set_host_disk() {
  local file="$1" name="$2" disk="$3" tmp
  if ! grep -qE "^[[:space:]]+${name}[[:space:]]*=[[:space:]]*\{" "$file"; then
    nh_err "no entry for $name in $file — the roster is not in the shape 'host add' writes"
    return 1
  fi
  tmp="$(mktemp -t nixhold-hosts.XXXXXX)" || {
    nh_err "could not create a temp file to rewrite $file"
    return 1
  }
  if ! name="$name" disk="$disk" awk '
    BEGIN { inside = 0; done = 0; replaced = 0 }
    {
      if (!inside && !done && $0 ~ ("^[[:space:]]+" ENVIRON["name"] "[[:space:]]*=[[:space:]]*\\{")) {
        inside = 1
        indent = $0
        sub(/[^ \t].*$/, "", indent)
        close_re = "^" indent "\\};[[:space:]]*$"
        print
        next
      }
      if (inside) {
        line = indent "  disk = \"" ENVIRON["disk"] "\";"
        if ($0 ~ /^[[:space:]]+disk[[:space:]]*=/) { print line; replaced = 1; next }
        if ($0 ~ close_re) {
          if (!replaced) print line
          inside = 0
          done = 1
        }
      }
      print
    }
  ' "$file" >"$tmp" || ! mv "$tmp" "$file"; then
    rm -f "$tmp"
    nh_err "could not write the disk into $file"
    return 1
  fi
}

# nh_facter_target <name> — where this install writes the hardware
# report: `nixhold.hardware.facterReport` as the host evaluates it,
# re-rooted from the store copy to the operator's working tree.
nh_facter_target() {
  local name="$1" abspath
  abspath="$(nh_host_eval "$name" nixos nixhold.hardware.facterReport | jq -r '. // empty')" || return 2
  if [ -z "$abspath" ]; then
    nh_err "$name sets nixhold.hardware.facterReport = null — the install has nowhere to write the hardware report"
    return 1
  fi
  nh_reroot_layout hostsDir "$abspath"
}

# nh_disk_json <remote> — the target's block devices with their
# children. One lsblk call feeds both the picker rows and the
# confirmation's partition list, so the operator confirms exactly what
# the picker described. PTTYPE/PARTTYPE are dropped on older util-linux
# builds that lack the columns.
nh_disk_json() {
  local remote="$1" json
  json="$(nh_target_sh "$remote" \
    "lsblk -J -o NAME,SIZE,MODEL,TRAN,TYPE,PTTYPE,FSTYPE,LABEL,PARTTYPE,MOUNTPOINT" 2>/dev/null)" ||
    json="$(nh_target_sh "$remote" \
      "lsblk -J -o NAME,SIZE,MODEL,TRAN,TYPE,FSTYPE,LABEL,MOUNTPOINT" 2>/dev/null)" ||
    return 1
  printf '%s' "$json"
}

# nh_disk_rows — lsblk JSON on stdin, one padded picker row per
# installable whole disk on stdout: name, size, model, bus, and a
# current-contents summary (partition table, previous install, child
# filesystems, or "empty") so the choice is about content rather than
# device names.
#
# The installer medium is excluded: on a live image the ISO's own
# device is the one with /iso (or the read-only store) mounted off a
# child, which is the only mount present that early. Removable disks
# are NOT excluded — a target may be an SSD in a USB enclosure.
nh_disk_rows() {
  jq -r '
    def orq(d): if (. == null or . == "") then d else . end;
    def mounts: ([ .mountpoint ] + (.mountpoints // []))
      | map(select(. != null and . != ""));
    def installer_medium:
      ([ . ] + (.children // []))
      | map(mounts) | add // []
      | map(select(. == "/iso" or . == "/nix/.ro-store" or startswith("/iso/")))
      | length > 0;
    def pdesc:
      [ (.size | orq("?")), (.fstype | orq("unformatted")) ]
      + (if (.label | orq("")) == "" then [] else [ "\"" + .label + "\"" ] end)
      | join(" ");
    def summary:
      (.children // []) as $c
      | if ($c | length) == 0 then "empty"
        else
          ((.pttype | orq("")) | if . == "" then [] else [ . ] end) as $pt
          | ([ $c[] | select((.label | orq("")) | ascii_downcase == "nixos") ] | length > 0) as $lbl
          | ((([ $c[] | select(((.parttype | orq("")) | ascii_downcase) == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b"
                               or (.fstype | orq("")) == "vfat") ] | length) > 0)
             and (([ $c[] | select((.fstype | orq("")) == "ext4") ] | length) > 0)) as $shape
          | ($pt
             + (if $lbl then [ "previous NixOS install" ]
                elif $shape then [ "previous Linux install" ]
                else [] end)
             + [ ([ $c[] | pdesc ]
                  | if length > 4 then .[0:4] + [ "+" + ((length - 4) | tostring) + " more" ] else . end
                  | join(", ")) ])
            | join(" · ")
        end;
    .blockdevices[]
    | select(.type == "disk")
    # zram/ram are TYPE=disk to lsblk and can never be install targets.
    | select(.name | test("^(zram|ram)[0-9]*$") | not)
    | select(installer_medium | not)
    | [ .name, (.size | orq("?")), (.model | orq("unknown")), (.tran | orq("-")), summary ]
    | @tsv
  ' | awk -F'\t' '{ printf "%-10s %8s  %-28.28s %-5s  %s\n", $1, $2, $3, $4, $5 }'
}

# nh_disk_partitions <disk-name> — lsblk JSON on stdin, the exact
# partitions about to be erased (name, size, fstype, label) for the
# destructive confirmation. Empty output = no partitions.
nh_disk_partitions() {
  local name="$1"
  jq -r --arg n "$name" '
    def orq(d): if (. == null or . == "") then d else . end;
    .blockdevices[]
    | select(.type == "disk" and .name == $n)
    | (.children // [])[]
    | [ ("/dev/" + .name), (.size | orq("?")), (.fstype | orq("-")), (.label | orq("-")) ]
    | @tsv
  ' | awk -F'\t' '{ printf "    %-14s %8s  %-10s %s\n", $1, $2, $3, $4 }'
}

# nh_disk_byid <remote> <name> — stable /dev/disk/by-id path for a
# whole disk. Prefers a non-wwn alias (model+serial reads better in a
# committed disko.nix) and picks deterministically by sort order;
# falls back to /dev/<name> when the target exposes no alias.
nh_disk_byid() {
  local remote="$1" name="$2" links byid
  links="$(nh_target_sh "$remote" "
    for l in /dev/disk/by-id/*; do
      [ -e \"\$l\" ] || continue
      [ \"\$(readlink -f \"\$l\")\" = \"/dev/$name\" ] && printf '%s\n' \"\$l\"
    done | sort" 2>/dev/null || true)"
  byid="$(printf '%s\n' "$links" | grep -v '/wwn-' | head -n1 || true)"
  [ -n "$byid" ] || byid="$(printf '%s\n' "$links" | head -n1 || true)"
  if [ -n "$byid" ]; then
    printf '%s' "$byid"
  else
    nh_warn "no /dev/disk/by-id alias for $name; using /dev/$name (less stable)"
    printf '/dev/%s' "$name"
  fi
}

# nh_pick_disk <remote> — enriched picker plus the destructive
# confirmation (default NO); prints the chosen disk as a by-id path.
# The operator never types or copies a device path.
nh_pick_disk() {
  local remote="$1" json rows chosen name parts
  json="$(nh_disk_json "$remote")" || {
    nh_err "lsblk failed${remote:+ over ssh against $remote}"
    return 1
  }
  rows="$(printf '%s' "$json" | nh_disk_rows)" || return 1
  if [ -z "$rows" ]; then
    nh_err "no installable whole disk found${remote:+ on $remote} (the installer medium is excluded)"
    return 1
  fi
  chosen="$(printf '%s\n' "$rows" | gum choose --header "Root disk to install onto (ERASED):")" || return 1
  name="$(printf '%s' "$chosen" | awk '{ print $1 }')"
  [ -n "$name" ] || return 1

  parts="$(printf '%s' "$json" | nh_disk_partitions "$name")"
  nh_warn "/dev/$name is about to be ERASED — this is destroyed:"
  if [ -n "$parts" ]; then
    printf '%s\n' "$parts" >&2
  else
    printf '    (no partitions — the disk is empty)\n' >&2
  fi
  gum confirm --default=false "Erase /dev/$name and install?" || return 1

  nh_disk_byid "$remote" "$name"
}

# nh_pick_install_host — the install picker: every host this machine
# can install as a reformat candidate, plus "new host…". Prints the
# chosen name, or "new" for the add hand-off.
nh_pick_install_host() {
  local rows="" line name platform chosen
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    name="${line%% *}"
    platform="${line##* }"
    case "$platform" in
      nixos) rows="${rows}${name}	(reformat — erases its disk)
" ;;
      darwin)
        [ "$(uname -s)" = "Darwin" ] || continue
        rows="${rows}${name}	(darwin — activates this Mac)
" ;;
    esac
  done < <(nh_hosts)
  rows="${rows}new host…"
  chosen="$(printf '%s\n' "$rows" | gum choose --header "Install which host?")" || return 1
  if [ "$chosen" = "new host…" ]; then
    printf 'new'
  else
    printf '%s' "$chosen" | awk '{ print $1 }'
  fi
}

# nh_stage_host_key <name> <dir> — resolve the host's SSH key into
# <dir> (cache, else committed escrow) and backfill the committed pair
# (host.pub + host.key.age) from the resolved key when the cache
# answered and nothing is escrowed yet (principle 16: every host.pub
# has a sibling host.key.age).
nh_stage_host_key() {
  local name="$1" dir="$2" keys_dir
  nh_resolve_host_key "$name" "$dir" || return 1
  keys_dir="$(nh_worktree_keys_dir)" || return 0
  if [ ! -f "$keys_dir/hosts/$name/host.key.age" ]; then
    nh_escrow_host_key "$name" "$dir/ssh_host_ed25519_key" ||
      nh_warn "host-key escrow for $name not written — 'nixhold lint' will flag it"
  fi
}

# nh_local_install <name> <root> <facter> — the ISO path: the remote
# path's phases run in place, in the remote path's order.
#
# Everything that can fail or prompt — key resolution (no escrow, wrong
# passphrase) and secret bootstrap ($EDITOR) — runs BEFORE disko
# touches the disk. Reversed, a passphrase typo left the operator with
# a wiped machine and nothing installed on it.
#
# Called as `nh_local_install … || rc=$?`, so errexit is off in here:
# every step is checked explicitly.
nh_local_install() {
  local name="$1" root="$2" facter_target="$3"

  # Baked into the installer ISO; requiring them here is what makes
  # the local path honest outside it.
  nh_require_cmd disko nixos-facter nixos-install || {
    nh_err "local install needs disko, nixos-facter and nixos-install on PATH — they ship in the nixhold installer ISO"
    return 1
  }

  # Host key before the closure build: agenix decrypts with it on the
  # first activation pass, which nixos-install runs.
  local keydir
  keydir="$(nh_tmpdir hostkey)" || return 1
  nh_stage_host_key "$name" "$keydir" || return 1

  # Before the disk is touched AND before the build, so a host
  # first-boots with every required secret decryptable. Fatal, as in
  # `deploy`: activation would only fail later with a worse error.
  nh_provision_required_secrets "$name" nixos || {
    nh_err "secret provisioning failed — fix the secrets above, then re-run install (nothing has been erased)"
    return 1
  }

  nh_info "partitioning + mounting per $name's disko.devices"
  nh_sudo disko --mode destroy,format,mount --yes-wipe-all-disks --flake "$root#$name" || {
    nh_err "disko failed — nothing was installed"
    return 1
  }

  nh_sudo install -d -m 0755 /mnt/etc/ssh || {
    nh_err "could not create /mnt/etc/ssh"
    return 1
  }
  nh_sudo install -m 0600 "$keydir/ssh_host_ed25519_key" /mnt/etc/ssh/ssh_host_ed25519_key || {
    nh_err "could not stage the host key into /mnt/etc/ssh"
    return 1
  }
  nh_sudo install -m 0644 "$keydir/ssh_host_ed25519_key.pub" /mnt/etc/ssh/ssh_host_ed25519_key.pub || {
    nh_err "could not stage the host pubkey into /mnt/etc/ssh"
    return 1
  }
  nh_ok "staged the host key into /mnt/etc/ssh"

  nh_info "generating the hardware report"
  nh_sudo nixos-facter -o "$facter_target" || {
    nh_err "nixos-facter failed"
    return 1
  }
  nh_stage_for_eval "$root" "$facter_target"
  nh_ok "wrote $facter_target"

  nh_info "building $name's system closure"
  local out
  out="$(nix build --no-link --print-out-paths --no-warn-dirty \
    "$root#nixosConfigurations.$name.config.system.build.toplevel")" || {
    nh_err "closure build failed"
    return 1
  }

  nh_info "installing $out into /mnt"
  nh_sudo nixos-install --root /mnt --system "$out" --no-root-passwd || {
    nh_err "nixos-install failed"
    return 1
  }
  nh_ok "installed $name"
}

# nh_darwin_install <name> <root> — local darwin install, fresh-macOS
# capable. Does the two jobs the NixOS path gets from nixos-anywhere:
#   1. host identity — make /etc/ssh/ssh_host_ed25519_key (agenix's
#      darwin identityPath) BE the fleet's key for <name>: the shared
#      reconciliation (nh_reconcile_host_key), which installs the
#      committed key, adopts the machine's when the fleet has none,
#      or mints one for a host that has never had one; an adoption
#      rekeys the secrets to it;
#   2. activate — sudo darwin-rebuild; on a machine that has never
#      switched (no darwin-rebuild on PATH), bootstrap via the fleet's
#      pinned nix-darwin.
nh_darwin_install() {
  local name="$1" root="$2"

  if [ "$(uname -s)" != "Darwin" ]; then
    nh_err "darwin install runs on the Mac itself — run this on $name"
    return 1
  fi

  # 1. Host identity. The install is the confirmation.
  nh_reconcile_host_key "$name" "" 1 || return 1
  if [ "$_NH_KEY_ADOPTED" -eq 1 ]; then
    nh_info "re-encrypting secrets to include the host recipient"
    . "$NIXHOLD_LIB_ROOT/secret-rekey.sh"
    cmd_secret_rekey || {
      nh_err "rekey failed — secrets are NOT decryptable by $name yet; fix and re-run install"
      return 1
    }
  fi
  local keys_dir
  keys_dir="$(nh_worktree_keys_dir)" || return 2
  nh_commit_paths "$root" "host $name: host key" "$keys_dir/hosts/$name"

  # 2. Activate (nix-darwin requires root for switch).
  if command -v darwin-rebuild >/dev/null 2>&1; then
    (cd "$root" && sudo darwin-rebuild switch --flake ".#$name") || return $?
  else
    nh_info "darwin-rebuild not on PATH — first switch, bootstrapping via the fleet's pinned nix-darwin"
    local out
    out="$(nh_tmpdir darwin-bootstrap)" || return 1
    nix build --out-link "$out/system" "$root#darwinConfigurations.$name.system" || {
      nh_err "could not build $name's system closure"
      return 1
    }
    if ! (cd "$root" && sudo "$out/system/sw/bin/darwin-rebuild" switch --flake ".#$name"); then
      nh_err "first activation failed — if it complained about pre-existing files (/etc/nix/nix.conf, /etc/zshenv, …), move them aside (e.g. sudo mv /etc/nix/nix.conf{,.before-nix-darwin}) and re-run"
      return 1
    fi
  fi

  nh_ok "installed $name"
  nh_info "agenix decrypts via launchd shortly after activation — verify: ls /run/agenix (kick it: sudo launchctl kickstart -k system/activate-agenix)"
}

cmd_host_install() {
  local name="" remote="" disk="" yes=0 picked=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --remote) remote="$2"; shift 2 ;;
      --disk) disk="$2"; shift 2 ;;
      --yes) yes=1; shift ;;
      -h | --help)
        cat <<'EOF'
Usage: nixhold host install [<name>] [--remote <user>@<ip>]
                                     [--disk <by-id>] [--yes]

  <name> omitted   pick a host: any fleet host this machine can
                   install (reformat), or "new host…" to walk one in.
  --remote         drive the install over SSH from a fleet machine.
                   Without it the install targets THIS machine (the
                   installer ISO); elsewhere the address is asked for.
  --disk           the install disk (/dev/disk/by-id/…), written into
                   the roster; without it the picker asks, or the
                   roster's disk is reused.
EOF
        return 0
        ;;
      -*) nh_err "unknown flag: $1"; return 1 ;;
      *) if [ -z "$name" ]; then name="$1"; shift; else nh_err "extra arg: $1"; return 1; fi ;;
    esac
  done

  nh_require_cmd nix jq
  local root
  root="$(nh_fleet_root)" || return 2

  # Host selection.
  if [ -z "$name" ]; then
    if ! nh_tty; then
      nh_err "expected: nixhold host install <name>"
      return 1
    fi
    nh_require_cmd gum
    name="$(nh_pick_install_host)" || return 1
    if [ "$name" = "new" ]; then
      # The add walk ends with its own install question.
      . "$NIXHOLD_LIB_ROOT/host-add.sh"
      cmd_host_add
      return $?
    fi
  fi

  local platform arch
  platform="$(nh_host_platform "$name")" || {
    nh_err "host '$name' is not in this fleet — 'nixhold status --fleet' lists the roster"
    return 1
  }
  arch="$(nh_host_arch "$name")"

  case "$arch" in
    *-darwin)
      if [ -n "$remote" ]; then
        nh_warn "--remote is ignored for darwin hosts (install runs locally)"
      fi
      nh_darwin_install "$name" "$root"
      return $?
      ;;
    *-linux) ;;
    *)
      nh_err "unsupported arch: $arch"
      return 1
      ;;
  esac

  # Local means THIS machine, which only the installer ISO may be.
  # Elsewhere the walk asks where the booted installer is.
  if [ -z "$remote" ] && ! nh_installer_env; then
    if ! nh_tty; then
      nh_err "local install refused — pass --remote <user>@<ip> or boot the installer ISO"
      return 1
    fi
    nh_info "this machine is not the installer — $name installs over ssh to a target booted from the fleet ISO (or any installer)"
    remote="$(nh_prompt_input "Installer address (root@<ip>)")" || remote=""
    if [ -z "$remote" ]; then
      nh_err "no address — boot the target from the fleet ISO, then: nixhold host install $name --remote root@<ip>"
      return 1
    fi
  fi
  if [ -n "$remote" ]; then nh_require_cmd ssh; fi

  local hosts_file facter_target
  hosts_file="$(nh_worktree_layout_file hostsFile)" || return 2
  facter_target="$(nh_facter_target "$name")" || return $?
  mkdir -p "$(dirname "$facter_target")"

  # 1. Disk. The roster holds it; a host with `disko.devices` of its
  #    own is never asked. --disk answers the picker for scripted runs.
  local current custom=0
  current="$(nh_host_field "$name" disk)"
  if [ -z "$current" ] && [ -z "$disk" ] &&
    [ "$(nh_host_eval "$name" nixos disko.devices.disk | jq 'length > 0')" = "true" ]; then
    custom=1
    nh_info "$name declares its own disko.devices — formatting what it names"
  fi
  if [ -z "$disk" ] && [ "$custom" -ne 1 ]; then
    if [ -n "$current" ] && { [ "$yes" -eq 1 ] || ! nh_tty ||
      nh_prompt_confirm "Reinstall $name onto its roster disk $current? (No: pick another)"; }; then
      disk="$current"
    else
      if ! nh_tty; then
        nh_err "no disk for $name — pass --disk <by-id>, or declare disko.devices in its module"
        return 1
      fi
      nh_require_cmd gum
      disk="$(nh_pick_disk "$remote")" || {
        nh_info "aborted"
        return 1
      }
      picked=1
    fi
  fi
  if [ -n "$disk" ] && [ "$disk" != "$current" ]; then
    nh_set_host_disk "$hosts_file" "$name" "$disk" || return 1
    nh_stage_for_eval "$root" "$hosts_file"
    nh_fleet_view_reset
    nh_ok "wrote disk = \"$disk\" for $name into $hosts_file"
  fi

  # 2. Confirm. The picker already confirmed against the partition
  #    list; the --disk / roster / custom-layout paths would otherwise
  #    reformat with zero prompt.
  if [ "$yes" -ne 1 ] && [ "$picked" -ne 1 ]; then
    local what="$disk"
    [ -n "$what" ] || what="every disk in the disko.devices of $name"
    nh_warn "$what will be ERASED and $name reinstalled from scratch${remote:+ (target: $remote)}"
    nh_prompt_confirm "Proceed with the destructive install of $name?" || {
      nh_info "aborted"
      return 0
    }
  fi

  local rc=0
  if [ -z "$remote" ]; then
    nh_local_install "$name" "$root" "$facter_target" || rc=$?
  else
    # 3. Stage the host's SSH key so agenix decrypts on the first
    #    activation pass (placed before nixos-install runs).
    #    nixos-anywhere is checked BEFORE key material lands in
    #    $TMPDIR; the staging dir is under the process scratch root the
    #    dispatcher wipes on every exit path.
    nh_require_cmd nixos-anywhere
    local extra
    extra="$(nh_tmpdir extra-files)" || return 1
    mkdir -p "$extra/etc/ssh" || {
      nh_err "could not create the staging tree under $extra"
      return 1
    }
    nh_stage_host_key "$name" "$extra/etc/ssh" || return 1

    # Before the build, so the host first-boots with every required
    # secret decryptable. Fatal, as in `deploy`.
    nh_provision_required_secrets "$name" nixos || {
      nh_err "secret provisioning failed — fix the secrets above, then re-run install"
      return 1
    }

    # 4. Install. The target builds its own closure
    #    (--build-on-remote); nixos-facter writes the hardware report
    #    back to facter.json.
    nh_info "running nixos-anywhere against $name @ $remote"
    # nixos-anywhere drives its own ssh with UserKnownHostsFile=/dev/null
    # and StrictHostKeyChecking=no (its hard defaults, not ours) and the
    # host key cannot be pinned anyway: the machine answering is the
    # installer ISO, whose key is random per boot. The connection is
    # therefore trust-on-first-use, and it carries $name's private key
    # in --extra-files — run installs over a network you trust.
    nixos-anywhere \
      --flake "$root#$name" \
      --generate-hardware-config nixos-facter "$facter_target" \
      --extra-files "$extra" \
      --build-on-remote \
      --target-host "$remote" || rc=$?
    if [ "$rc" -eq 0 ]; then
      nh_ok "installed $name"
    else
      nh_err "nixos-anywhere failed (exit $rc)"
    fi
  fi

  # 5. The machine is bootable by now; the repo side is best-effort.
  #    The roster's disk and the facter report are install-time
  #    outputs (plus the host-key escrow when the install backfilled
  #    it), committed on success — auto-commit never reaches beyond
  #    them. On the installer the checkout is ephemeral, so the commit
  #    is pushed too.
  if [ "$rc" -eq 0 ]; then
    local keys_dir
    keys_dir="$(nh_worktree_keys_dir 2>/dev/null)" || keys_dir="$root/keys"
    nh_commit_paths "$root" "host $name: install (disk + facter)" \
      "$hosts_file" "$facter_target" "$keys_dir/hosts/$name"
    nh_push_if_installer "$root"
    nh_info "next: once $name is on the tailnet, 'nixhold deploy $name' for every change after this"
  fi
  return "$rc"
}
