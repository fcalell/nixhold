# nixhold host install [<name>] [--remote <user>@<ip>] [--disk <by-id>]
#                               [--yes] [--repo <owner/repo> --keys <dir>]
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
# Keys: the install stages two things onto the target before it boots.
# /etc/nixhold/fleet.key (0400 root) + /etc/nixhold/fleet.pub (0444) —
# the one age identity every host decrypts its secrets with, so agenix
# opens them on the first activation pass. And a FRESH ed25519 SSH host
# key, generated here so its public half is known before first boot and
# committed as keys/hosts/<name>.pub, which is all the fleet uses it
# for (known_hosts pinning). Host keys are random per install and are
# recipients of nothing: a re-image mints a new one and rekeys nothing.
#
# Disk: the roster field `hosts.<name>.disk`, written by the picker
# (or --disk); the framework renders its one disko shape from it. A
# picker runs on every install and never reads the roster value, so a
# stale or hand-written path cannot steer a reformat. A
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

# nh_target_sudo_sh <remote> <sh-snippet> — nh_target_sh for a snippet
# that escalates: `nh_rsudo <cmd…>` is defined for it either way.
# Locally sudo prompts on the terminal itself; remotely the password is
# fed to `sudo -S` on the first line of stdin (lib/ssh.sh). The target
# is normally the installer ISO, which runs as root and escalates
# nowhere — the escalation only matters when the operator points
# --remote at an already-installed machine.
nh_target_sudo_sh() {
  local remote="$1" script="$2"
  if [ -z "$remote" ]; then
    sh -c "$(nh_sudo_preamble_local)
$script"
  else
    nh_ssh_sudo "$remote" -- "$script" </dev/null
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

# nh_disk_esps <disk-name> — lsblk JSON on stdin, the names of the
# EFI system partitions on that disk (by partition type GUID, or
# vfat when the lsblk build lacks PARTTYPE), one per line.
nh_disk_esps() {
  jq -r --arg n "$1" '
    def orq(d): if (. == null or . == "") then d else . end;
    .blockdevices[]
    | select(.type == "disk" and .name == $n)
    | (.children // [])[]
    | select(((.parttype | orq("")) | ascii_downcase) == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b"
             or ((.parttype | orq("")) == "" and (.fstype | orq("")) == "vfat"))
    | .name'
}

# nh_esp_loaders <remote> <partition-name> — the entries under /EFI
# of that partition, read through a read-only mount on the target
# (root on the ISO, root or sudo elsewhere). Empty when it cannot be
# mounted or holds no /EFI.
nh_esp_loaders() {
  local remote="$1" part="$2"
  # shellcheck disable=SC2016 # runs on the TARGET's shell
  nh_target_sudo_sh "$remote" '
    d="$(mktemp -d)" || exit 0
    if nh_rsudo mount -o ro "/dev/'"$part"'" "$d" 2>/dev/null; then
      ls "$d/EFI" 2>/dev/null
      nh_rsudo umount "$d" 2>/dev/null
    fi
    rmdir "$d" 2>/dev/null
    exit 0' 2>/dev/null || true
}

# nh_foreign_loaders — /EFI entries on stdin, those that are not
# systemd-boot's own (BOOT, systemd, Linux, nixos) on stdout: another
# OS's loader lives there.
nh_foreign_loaders() {
  awk 'BEGIN { IGNORECASE = 1 } NF && $0 !~ /^(BOOT|systemd|Linux|nixos)$/ { print }'
}

# nh_name_os <efi-entry> — what the operator calls the OS behind an
# /EFI entry.
nh_name_os() {
  case "$1" in
    Microsoft | microsoft) printf 'Windows' ;;
    *) printf 'another OS (EFI/%s)' "$1" ;;
  esac
}

# nh_esp_guard <remote> <lsblk-json> <disk-name> — the second OS walk.
# The chosen disk's ESP holding another OS's loader means that OS
# stops booting when the disk is erased: name it and require a second
# explicit confirmation. A Windows ESP on a NON-target disk is left
# alone and gets the one line that lists it in systemd-boot's menu
# (the firmware menu boots it regardless).
nh_esp_guard() {
  local remote="$1" json="$2" target="$3" part entry other names=""
  local -a parts entries
  # Collected before the prompt: gum reads its answer from stdin, and a
  # loop fed by a process substitution hands it the pipe's EOF, which
  # counts as No. One decision per disk, so every foreign loader is
  # named first and the question comes once.
  mapfile -t parts < <(printf '%s' "$json" | nh_disk_esps "$target")
  for part in "${parts[@]}"; do
    [ -n "$part" ] || continue
    mapfile -t entries < <(nh_esp_loaders "$remote" "$part" | nh_foreign_loaders)
    for entry in "${entries[@]}"; do
      [ -n "$entry" ] || continue
      nh_warn "the ESP /dev/$part on /dev/$target holds the boot files of $(nh_name_os "$entry") — that OS stops booting when this disk is erased; move it to an ESP on its own disk first (Windows: bcdboot from a recovery environment)"
      names="${names:+$names, }$(nh_name_os "$entry")"
    done
  done
  if [ -n "$names" ]; then
    gum confirm --default=false "Erase /dev/$target anyway and leave $names unbootable?" || return 1
  fi

  while IFS= read -r other; do
    [ -n "$other" ] || continue
    while IFS= read -r part; do
      [ -n "$part" ] || continue
      if nh_esp_loaders "$remote" "$part" | grep -qix microsoft; then
        nh_info "Windows boots from its own ESP /dev/$part on /dev/$other, which this install never touches. To list it in systemd-boot's menu, set in the host module:"
        nh_info "  boot.loader.systemd-boot.windows.\"11\".efiDeviceHandle = \"HD0b\";  # key = the version shown in the menu; the handle is what \`map -c\` prints for that ESP in the UEFI shell"
      fi
    done < <(printf '%s' "$json" | nh_disk_esps "$other")
  done < <(printf '%s' "$json" | jq -r --arg t "$target" '.blockdevices[] | select(.type == "disk" and .name != $t) | .name')
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
  nh_esp_guard "$remote" "$json" "$name" || return 1
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

# nh_stage_host_key <name> <dir> — a fresh SSH host key for <name> in
# <dir> (ssh_host_ed25519_key + .pub, the names sshd wants), with the
# public half committed as keys/hosts/<name>.pub and staged so the
# dirty-flake eval that builds the closure can see it. The private half
# never leaves the process scratch root and the fleet never keeps a
# copy: it identifies the machine, and nothing is encrypted to it.
nh_stage_host_key() {
  local name="$1" dir="$2"
  nh_generate_host_key "$name" "$dir" || return 1
  nh_commit_host_pub "$name" "$dir/ssh_host_ed25519_key.pub" >/dev/null || return 1
  nh_ok "generated $name's SSH host key; its pubkey is committed as keys/hosts/$name.pub"
}

# nh_local_install <name> <root> <facter> — the ISO path: the remote
# path's phases run in place, in the remote path's order.
#
# Everything that can fail or prompt — opening the fleet key (a wrong
# passphrase, a token that never got touched) and secret bootstrap
# ($EDITOR) — runs BEFORE disko touches the disk. Reversed, a
# passphrase typo left the operator with a wiped machine and nothing
# installed on it.
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

  # Before the disk is touched AND before the build, so a host
  # first-boots with every required secret decryptable. Fatal, as in
  # `deploy`: activation would only fail later with a worse error.
  nh_provision_required_secrets "$name" nixos || {
    nh_err "secret provisioning failed — fix the secrets above, then re-run install (nothing has been erased)"
    return 1
  }

  # The fleet key has to be readable HERE before the disk is touched:
  # it is decrypted over the operator's route (a passphrase prompt, a
  # token touch) and staged into the new root below. Discovered now it
  # costs a re-run; discovered after disko it costs an erased machine.
  local keydir
  keydir="$(nh_tmpdir hostkey)" || return 1
  nh_fleet_key_plain >/dev/null || {
    nh_err "the fleet key could not be opened — nothing has been erased"
    return 1
  }

  nh_info "partitioning + mounting per $name's disko.devices"
  nh_sudo disko --mode destroy,format,mount --yes-wipe-all-disks --flake "$root#$name" || {
    nh_err "disko failed — nothing was installed"
    return 1
  }

  # A fresh host key, generated after the disk exists but before the
  # closure is built: keys/hosts/<name>.pub is committed here and the
  # known-hosts module reads it in the very build below.
  nh_stage_host_key "$name" "$keydir" || return 1

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

  # agenix decrypts with /etc/nixhold/fleet.key on the first activation
  # pass, which nixos-install runs.
  nh_fleet_key_install --root /mnt || {
    nh_err "could not stage the fleet key into /mnt/etc/nixhold"
    return 1
  }

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

# nh_bootstrap_fleet <owner/repo> <keys-dir> — the fresh-Mac path: no
# fleet checkout exists yet, so clone one into the framework's
# checkout directory (lib/defaults.nix, where every declared
# repository lives too) over the fleet's own `identity` ssh key.
# nh_fleet_relocate then moves it to whatever this fleet's own
# `programs.nixhold.fleetDir` names, once there is a checkout to read
# that from. <keys-dir> holds the operator-encrypted
# ciphertexts the ISO bakes for the same purpose — identity.age always,
# operator.age only on a fleet that has a passphrase identity at all —
# read through the same $NIXHOLD_IDENTITY_FILE / $NIXHOLD_CLONE_KEY_FILE
# path, so the operator's seat (the passphrase, or the token in their
# pocket) is all they bring.
_NH_BOOTSTRAPPED=0
nh_bootstrap_fleet() {
  local repo="$1" keys="$2" dir parent remote
  case "$repo" in
    */*) ;;
    *)
      nh_err "--repo expects owner/repo (got '$repo')"
      return 1
      ;;
  esac
  if [ ! -f "$keys/identity.age" ]; then
    nh_err "--keys $keys holds no identity.age — copy it there from any checkout (it is secrets/identity.age, the fleet's own ssh key, and what clones the fleet)"
    return 1
  fi
  NIXHOLD_CLONE_KEY_FILE="$keys/identity.age"
  export NIXHOLD_CLONE_KEY_FILE
  # A token-only fleet ships no wrapped identity: the token is the
  # seat, and there is no checkout to read its recipient from yet, so
  # the route falls to whatever is plugged in.
  if [ -f "$keys/operator.age" ]; then
    NIXHOLD_IDENTITY_FILE="$keys/operator.age"
    export NIXHOLD_IDENTITY_FILE
  elif nh_age_token_present; then
    nh_info "no operator.age in $keys — decrypting with the FIDO2 token that is plugged in"
  else
    nh_err "--keys $keys holds no operator.age and no FIDO2 token is plugged in — nothing can decrypt the clone key; plug the token in, or copy keys/operator.age there"
    return 1
  fi

  # The framework's checkout directory, baked into the CLI package
  # from lib/defaults.nix: nothing here can be evaluated yet, and
  # this is the clone that makes evaluation possible. A fleet that
  # overrides `nixhold.home.repositoriesDir` is honoured by
  # nh_fleet_relocate, which runs once the option is readable.
  parent="${NIXHOLD_REPOSITORIES_DIR:-}"
  if [ -z "$parent" ]; then
    nh_err "\$NIXHOLD_REPOSITORIES_DIR is unset — the packaged 'nixhold' bakes it in; run that rather than these sources"
    return 1
  fi
  dir="$parent/${repo##*/}"
  dir="${dir%.git}"
  if [ -f "$dir/flake.nix" ]; then
    nh_info "fleet checkout already at $dir"
  else
    nh_require_cmd git || return 1
    remote="git@github.com:${repo%.git}.git"
    nh_info "cloning $remote into $dir over the fleet identity key"
    _NH_CLONING=1
    if ! nh_repo_git clone "$remote" "$dir" >&2; then
      _NH_CLONING=0
      nh_err "clone of $remote failed — the key in $keys/identity.age must be registered on the forge (it is the fleet's own identity key)"
      return 1
    fi
    _NH_CLONING=0
    _NH_BOOTSTRAPPED=1
    nh_ok "cloned fleet to $dir"
  fi
  _NH_FLEET_ROOT="$dir"
}

# nh_fleet_relocate <name> <platform> — put the checkout this
# invocation just cloned where the host will look for it.
#
# The clone lands at the framework's default directory because that
# is all a Mac with no fleet can know. `programs.nixhold.fleetDir` is
# the answer, and it becomes readable the moment the checkout exists,
# so the move happens here rather than leaving the machine with the
# checkout in one place and its baked default pointing at another —
# which is how an operator ends up with two.
nh_fleet_relocate() {
  local name="$1" platform="$2" want
  want="$(nh_host_eval "$name" "$platform" programs.nixhold.fleetDir | jq -r '. // empty')" || {
    nh_warn "could not read $name's programs.nixhold.fleetDir — the checkout stays at $_NH_FLEET_ROOT"
    return 0
  }
  [ -n "$want" ] && [ "$want" != "$_NH_FLEET_ROOT" ] || return 0
  if [ -e "$want" ]; then
    nh_warn "$name expects its fleet checkout at $want, where something already sits — leaving this one at $_NH_FLEET_ROOT"
    return 0
  fi
  nh_info "moving the checkout to $want, where $name looks for it"
  if ! mkdir -p "$(dirname "$want")" || ! mv "$_NH_FLEET_ROOT" "$want"; then
    nh_err "could not move the checkout to $want — it is still at $_NH_FLEET_ROOT"
    return 1
  fi
  _NH_FLEET_ROOT="$want"
  nh_ok "fleet checkout at $want"
}

# nh_darwin_preflight <name> — what a fresh Mac must already be
# before anything is written: logged in as the operator account
# (home, home-manager and agenix ownership all key off it), Command
# Line Tools present, and no Determinate Nix beside a host that
# manages Nix itself (nix-darwin refuses that activation).
nh_darwin_preflight() {
  local name="$1" want user
  want="$(nh_host_eval "$name" darwin nixhold.identity.username | jq -r '.')" || return 2
  user="$(id -un)"
  if [ "$user" != "$want" ]; then
    nh_err "logged in as '$user', but $name's operator account is '$want' — create that account (System Settings › Users & Groups, administrator) and run the install from it"
    return 1
  fi
  if ! xcode-select -p >/dev/null 2>&1; then
    nh_err "Command Line Tools are missing — run 'xcode-select --install', then re-run"
    return 1
  fi
  if [ -e /usr/local/bin/determinate-nixd ] &&
    [ "$(nh_host_eval "$name" darwin nix.enable | jq -r '.')" = "true" ]; then
    nh_err "Determinate Nix is installed and $name manages Nix itself — nix-darwin refuses to activate beside it; uninstall Determinate for the vanilla multi-user install, or set nix.enable = false in the host module"
    return 1
  fi
  nh_ok "preflight: account $user, Command Line Tools present, Nix manageable"
}

# nh_darwin_rebuild_cmd <root> <name> — the darwin-rebuild to switch
# with: the installed one, or, on a machine that has never switched,
# the fleet's pinned nix-darwin built into the scratch root.
nh_darwin_rebuild_cmd() {
  local root="$1" name="$2" out
  if command -v darwin-rebuild >/dev/null 2>&1; then
    printf 'darwin-rebuild'
    return 0
  fi
  nh_info "darwin-rebuild not on PATH — first switch, bootstrapping via the fleet's pinned nix-darwin"
  out="$(nh_tmpdir darwin-bootstrap)" || return 1
  nix build --out-link "$out/system" "$root#darwinConfigurations.$name.system" >&2 || {
    nh_err "could not build $name's system closure"
    return 1
  }
  printf '%s' "$out/system/sw/bin/darwin-rebuild"
}

# nh_darwin_switch <root> <name> <rebuild> — one `darwin-rebuild
# switch` (root, as nix-darwin requires). The first switch on a fresh
# Mac is refused when /etc holds files nix-darwin did not write
# (/etc/nix/nix.conf from the Nix installer, /etc/zshenv, …): those
# are moved to <file>.before-nix-darwin — the rename nix-darwin asks
# for — and the switch retried once.
nh_darwin_switch() {
  local root="$1" name="$2" rebuild="$3" log attempt files f
  log="$(nh_tmpdir switch)/log" || return 1
  for attempt in 1 2; do
    if (cd "$root" && sudo "$rebuild" switch --flake ".#$name" 2>&1 | tee "$log" >&2; exit "${PIPESTATUS[0]}"); then
      return 0
    fi
    [ "$attempt" -eq 1 ] || break
    grep -q "Unexpected files in /etc" "$log" || break
    files="$(awk '/would be overwritten:/ { f = 1; next } f && /^  \// { print $1; next } f && NF { exit }' "$log")"
    [ -n "$files" ] || break
    nh_warn "nix-darwin refuses to overwrite files in /etc it did not write — moving them aside and retrying once"
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      sudo mv "$f" "$f.before-nix-darwin" || {
        nh_err "could not move $f aside"
        return 1
      }
      nh_info "  $f → $f.before-nix-darwin"
    done <<<"$files"
  done
  nh_err "activation of $name failed — see above"
  return 1
}

# nh_darwin_wait_secrets <name> — agenix on darwin decrypts under
# launchd after activation, asynchronously: wait (bounded) for every
# active secret's path to exist, kickstart the daemon once when it
# does not, and say what is still missing. Non-zero when something
# is.
nh_darwin_wait_secrets() {
  local name="$1" paths
  paths="$(nh_host_eval "$name" darwin age.secrets | jq -r '.[] | .path')" || return 0
  [ -n "$paths" ] || return 0
  nh_info "waiting for agenix to decrypt $(printf '%s\n' "$paths" | grep -c .) secret(s) under /run/agenix"
  if nh_wait_paths 30 "$paths"; then
    nh_ok "every active secret is decrypted"
    return 0
  fi
  nh_info "not decrypted yet — kickstarting system/activate-agenix"
  sudo launchctl kickstart -k system/activate-agenix 2>/dev/null ||
    nh_warn "could not kickstart system/activate-agenix"
  if nh_wait_paths 30 "$paths"; then
    nh_ok "every active secret is decrypted"
    return 0
  fi
  nh_warn "still missing after the kickstart: $(nh_missing_paths "$paths" | paste -sd' ' -)"
  nh_info "the usual cause is a stale /etc/nixhold/fleet.key — 'nixhold deploy $name' reinstalls it; 'sudo launchctl print system/activate-agenix' shows the daemon"
  return 1
}

# nh_wait_paths <seconds> <paths-newline-separated> — poll (as root:
# the secrets dir is not traversable by the operator) until every
# path exists or the bound is hit.
nh_wait_paths() {
  local bound="$1" paths="$2" i=0
  while [ "$i" -lt "$bound" ]; do
    [ -z "$(nh_missing_paths "$paths")" ] && return 0
    sleep 1
    i=$((i + 1))
  done
  [ -z "$(nh_missing_paths "$paths")" ]
}

nh_missing_paths() {
  local p
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    sudo test -e "$p" || printf '%s\n' "$p"
  done <<<"$1"
}

# nh_darwin_install <name> <root> — local darwin install, fresh-macOS
# complete:
#   0. preflight — account, Command Line Tools, vanilla Nix;
#   1. identity — a Mac that has never run sshd has no host key, so
#      `ssh-keygen -A` mints one; its live pubkey is recorded as
#      keys/hosts/<name>.pub (pinning only). Then the fleet key is put
#      at /etc/nixhold/fleet.key, which is what agenix decrypts with;
#   2. activate — sudo darwin-rebuild (bootstrapped from the fleet's
#      pinned nix-darwin on a machine that has never switched), with
#      the first-switch /etc refusal handled in place;
#   3. secrets verified under /run/agenix, then a second switch so
#      home-manager derives the .pub files of sshKey secrets.
nh_darwin_install() {
  local name="$1" root="$2"

  if [ "$(uname -s)" != "Darwin" ]; then
    nh_err "darwin install runs on the Mac itself — run this on $name"
    return 1
  fi

  nh_darwin_preflight "$name" || return 1

  # 1. Identity: the machine's own ssh key (recorded, never escrowed)
  #    and the fleet key (installed, so agenix can decrypt).
  nh_ensure_darwin_host_key || return 1
  local live
  live="$(nh_read_live_host_pub)" || return 1
  nh_commit_host_pub "$name" "$live" >/dev/null || return 1
  nh_fleet_key_install || {
    nh_err "the fleet key is not on this Mac — agenix would decrypt nothing; fix the operator route and re-run install"
    return 1
  }
  local keys_dir
  keys_dir="$(nh_worktree_keys_dir)" || return 2
  nh_commit_paths "$root" "host($name): pubkey" "$keys_dir/hosts/$name.pub"

  # Required secrets before the build, as on NixOS: activation would
  # only fail later with a worse error.
  nh_provision_required_secrets "$name" darwin || {
    nh_err "secret provisioning failed — fix the secrets above, then re-run install"
    return 1
  }

  # 2. Activate.
  local rebuild
  rebuild="$(nh_darwin_rebuild_cmd "$root" "$name")" || return 1
  nh_darwin_switch "$root" "$name" "$rebuild" || return 1

  # 3. Secrets, then the .pub files.
  nh_darwin_wait_secrets "$name" || true
  if [ "$(nh_host_eval "$name" darwin nixhold.secrets | jq 'any(.[]; .sshKey and .active)')" = "true" ]; then
    nh_info "switching again so home-manager derives the .pub files of the SSH keys"
    nh_darwin_switch "$root" "$name" "$rebuild" || return 1
  fi

  nh_ok "installed $name"
  nh_info "next: nixhold deploy $name for every change after this"
}

cmd_host_install() {
  local name="" remote="" disk="" yes=0 picked=0 repo="" keys=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --remote) remote="$2"; shift 2 ;;
      --disk) disk="$2"; shift 2 ;;
      --yes) yes=1; shift ;;
      --repo) repo="${2:-}"; shift 2 ;;
      --keys) keys="${2:-}"; shift 2 ;;
      -h | --help)
        cat <<'EOF'
Usage: nixhold host install [<name>] [--remote <user>@<ip>]
                                     [--disk <by-id>] [--yes]
                                     [--repo <owner/repo> --keys <dir>]

  <name> omitted   pick a host: any fleet host this machine can
                   install (reformat), or "new host…" to walk one in.
  --remote         drive the install over SSH from a fleet machine.
                   Without it the install targets THIS machine (the
                   installer ISO); elsewhere the address is asked for.
  --disk           the install disk (/dev/disk/by-id/…), written into
                   the roster; without it the picker asks.
  --repo, --keys   a Mac with no fleet checkout: clone owner/repo
                   over the fleet's identity key first, into the
                   directory its own fleetDir names. <dir> holds
                   identity.age, plus operator.age unless the
                   operator's seat is a FIDO2 token.
EOF
        return 0
        ;;
      -*) nh_err "unknown flag: $1"; return 1 ;;
      *) if [ -z "$name" ]; then name="$1"; shift; else nh_err "extra arg: $1"; return 1; fi ;;
    esac
  done

  nh_require_cmd nix jq
  if [ -n "$repo" ] || [ -n "$keys" ]; then
    if [ -z "$repo" ] || [ -z "$keys" ]; then
      nh_err "--repo and --keys go together"
      return 1
    fi
    nh_bootstrap_fleet "$repo" "$keys" || return 1
  fi
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
  if [ "$_NH_BOOTSTRAPPED" = 1 ]; then
    nh_fleet_relocate "$name" "$platform" || return 1
    root="$_NH_FLEET_ROOT"
  fi
  if [ "$platform" = "android" ]; then
    nh_err "$name is an Android host — nothing is installed on a device; 'nixhold deploy $name' converges it over adb"
    return 1
  fi

  # Preflight, ahead of all three entry paths (darwin, local ISO,
  # --remote) and therefore ahead of any disk or machine: every one of
  # them opens keys/fleet.key.age to stage /etc/nixhold/fleet.key,
  # which needs the operator's seat. Discovered here it costs a re-run;
  # discovered after disko it costs an erased machine.
  nh_age_route_check "the fleet key" || {
    nh_err "install refused — plug in the operator's FIDO2 token, or run this from a checkout that holds keys/operator.age (nothing has been touched)"
    return 1
  }

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

  # 1. Disk. The picker, on every install: the roster's `disk` is the
  #    picker's output (or --disk), never its input, so a stale or
  #    hand-written value cannot steer a reformat. A host with
  #    `disko.devices` of its own is never asked.
  local current custom=0
  current="$(nh_host_field "$name" disk)"
  if [ -z "$current" ] && [ -z "$disk" ] &&
    [ "$(nh_host_eval "$name" nixos disko.devices.disk | jq 'length > 0')" = "true" ]; then
    custom=1
    nh_info "$name declares its own disko.devices — formatting what it names"
  fi
  if [ -z "$disk" ] && [ "$custom" -ne 1 ]; then
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
  if [ -n "$disk" ] && [ "$disk" != "$current" ]; then
    nh_set_host_field "$hosts_file" "$name" disk "$disk" || return 1
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
    # 3. Stage what the machine needs before its first activation:
    #    /etc/nixhold/fleet.key (agenix decrypts with it on the first
    #    pass) and a fresh SSH host key whose pubkey this commits as
    #    keys/hosts/<name>.pub. nixos-anywhere is checked BEFORE key
    #    material lands anywhere; the staging dir is under the process
    #    scratch root the dispatcher wipes on every exit path, and
    #    --extra-files preserves the modes set here.
    nh_require_cmd nixos-anywhere
    local extra
    extra="$(nh_tmpdir extra-files)" || return 1
    mkdir -p "$extra/etc/ssh" || {
      nh_err "could not create the staging tree under $extra"
      return 1
    }
    nh_stage_host_key "$name" "$extra/etc/ssh" || return 1
    nh_fleet_key_install --stage "$extra" || {
      nh_err "the fleet key could not be staged — $name would first-boot unable to decrypt anything"
      return 1
    }

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
    # therefore trust-on-first-use, and it carries the fleet key and
    # $name's new host key in --extra-files — run installs over a
    # network you trust.
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
  #    The roster's disk, the facter report and the new host's pubkey
  #    are install-time outputs, committed on success — auto-commit
  #    never reaches beyond them. On the installer the checkout is
  #    ephemeral, so the commit is pushed too.
  if [ "$rc" -eq 0 ]; then
    local keys_dir
    keys_dir="$(nh_worktree_keys_dir 2>/dev/null)" || keys_dir="$root/keys"
    nh_commit_paths "$root" "host($name): install (disk + facter)" \
      "$hosts_file" "$facter_target" "$keys_dir/hosts/$name.pub"
    nh_push_if_installer "$root"
    nh_info "next: once $name is on the tailnet, 'nixhold deploy $name' for every change after this"
  fi
  return "$rc"
}
