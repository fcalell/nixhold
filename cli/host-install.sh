# nixhold host install [<name>] [--remote <user>@<ip>] [--disk <by-id>]
#                               [--yes] [--repo <owner/repo> --keys <dir>]
#
# Two entry points, one phase sequence (nh_install_phases), run on the
# target either way — in place on the installer ISO, or over ssh to
# one (ARCHITECTURE "Where a host is built"):
#   --remote  drive the install over SSH from any fleet machine. The
#             target is the fleet installer ISO booted on the machine:
#             it carries git, nix, disko, nixos-facter and
#             nixos-install and pins the forge's host keys, which is
#             what lets it clone the fleet and build its own closure.
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
# The build reads a committed tree: the hardware report is generated
# first, then the roster's `disk`, the report, the host's new pubkey
# and any minted secret are committed and pushed, and the target
# builds the fleet at that sha — from the checkout the CLI already
# holds on the ISO, from a clone made over the `identity` key on a
# remote installer, whose plaintext the install puts in the
# installer's RAM for exactly that clone.
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
# A Windows on ANOTHER disk whose loader sits on the target's ESP is
# carried across the format: `EFI/Microsoft` is read off the old ESP
# before disko and put back on the new one right after it, before the
# closure is built, and systemd-boot lists it on its own. Only with
# evidence — a Windows installation found on a non-target disk — and
# only Windows: nothing on the target disk survives, and no other
# loader is one systemd-boot would show.
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
# --installer, never --host: in --remote mode the machine answering is
# a booted installer, whose host key is generated fresh on every boot,
# so the fleet's committed key for <name> is NOT what it presents,
# there is nothing to pin to, and nothing worth writing into the
# operator's known_hosts either (lib/ssh.sh). These snippets read block
# devices; the host key itself never travels over them (it goes as a
# tar into /mnt/etc, nh_install_stage_tree).
nh_target_sh() {
  local remote="$1" script="$2"
  if [ -z "$remote" ]; then
    sh -c "$script"
  else
    nh_ssh "$remote" --installer -- "$script"
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
    nh_ssh_sudo "$remote" --installer -- "$script" </dev/null
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

# nh_windows_disks <remote> <lsblk-json> <target-disk> — the disks
# OTHER than <target> holding a Windows installation (an NTFS partition
# with Windows/System32, read through a read-only mount on the target),
# one name per line. <target> is skipped because a Windows there is
# erased either way; every disk walked here is one the install keeps.
#
# Non-zero, with a message, when such a disk holds a Windows volume
# that cannot be read at all. Both cases look exactly like "no NTFS
# holding Windows" to the walk, and that answer is what decides the
# loader carry: accepting it would erase the ESP and leave a Windows
# that is still on the machine unbootable.
#   BitLocker  lsblk reports the fstype of an encrypted volume as
#              "BitLocker"; there is no mount that looks inside it.
#   a refused read-only mount  Fast Startup or hibernation left the
#              filesystem with a dirty log, which ntfs3 will not touch.
nh_windows_disks() {
  local remote="$1" json="$2" target="$3" pairs scan locked
  locked="$(printf '%s' "$json" | jq -r --arg t "$target" '
    .blockdevices[] | select(.type == "disk" and .name != $t)
    | (.children // [])[]
    | select(((.fstype // "") | ascii_downcase) == "bitlocker")
    | " /dev/\(.name)"' | tr -d '\n')"
  if [ -n "$locked" ]; then
    nh_err "BitLocker on$locked — the install cannot tell whether Windows lives there, so it cannot decide whether to carry Windows' loader across the format. Suspend BitLocker in Windows, reboot into the installer, and re-run (nothing has been erased)."
    return 1
  fi
  pairs="$(printf '%s' "$json" | jq -r --arg t "$target" '
    .blockdevices[] | select(.type == "disk" and .name != $t) | .name as $d
    | (.children // [])[] | select((.fstype // "") == "ntfs")
    | "\($d) \(.name)"')"
  [ -n "$pairs" ] || return 0
  # shellcheck disable=SC2016 # runs on the TARGET's shell
  scan="$(nh_target_sudo_sh "$remote" '
    d="$(mktemp -d)" || exit 1
    printf "%s\n" '"'$pairs'"' | while read -r disk part; do
      [ -n "$part" ] || continue
      if nh_rsudo mount -o ro -t ntfs3 "/dev/$part" "$d" 2>/dev/null ||
         nh_rsudo mount -o ro -t ntfs "/dev/$part" "$d" 2>/dev/null; then
        [ -d "$d/Windows/System32" ] && echo "windows $disk"
        nh_rsudo umount "$d" 2>/dev/null
      else
        echo "unreadable $part"
      fi
    done
    rmdir "$d" 2>/dev/null
    exit 0')" || {
    nh_err "could not look for Windows on the disks this install keeps — nothing has been erased"
    return 1
  }
  locked="$(printf '%s\n' "$scan" | awk '$1 == "unreadable" { printf " /dev/%s", $2 }')"
  if [ -n "$locked" ]; then
    nh_err "the NTFS filesystem on$locked refused a read-only mount — Fast Startup or hibernation left it with a dirty log, so the install cannot tell whether Windows lives there and cannot decide whether to carry Windows' loader across the format. Boot Windows and shut it down with Fast Startup off (or 'shutdown /s /t 0'), then re-run (nothing has been erased)."
    return 1
  fi
  printf '%s\n' "$scan" | awk '$1 == "windows" { print $2 }' | sort -u
}

# nh_windows_carry <remote> <lsblk-json> <disk-name> — the partition
# of the target disk whose EFI/Microsoft is carried into the new ESP:
# an ESP of that disk holding Windows' loader, when a Windows
# installation exists on some OTHER disk. Empty otherwise: a Windows
# on the target disk goes with it, loader included. Non-zero when the
# Windows walk could not reach a verdict (nh_windows_disks).
nh_windows_carry() {
  local remote="$1" json="$2" target="$3" part disks
  disks="$(nh_windows_disks "$remote" "$json" "$target")" || return 1
  [ -n "$disks" ] || return 0
  while IFS= read -r part; do
    [ -n "$part" ] || continue
    if nh_esp_loaders "$remote" "$part" | grep -qix microsoft; then
      printf '%s' "$part"
      return 0
    fi
  done < <(printf '%s' "$json" | nh_disk_esps "$target")
}

# nh_esp_tar <remote> <partition-name> — EFI/Microsoft of that ESP as
# a tar stream on stdout, read through a read-only mount on the
# target. The directory name is taken as the filesystem stores it.
nh_esp_tar() {
  local remote="$1" part="$2"
  # shellcheck disable=SC2016 # runs on the TARGET's shell
  nh_target_sudo_sh "$remote" '
    d="$(mktemp -d)" || exit 1
    nh_rsudo mount -o ro "/dev/'"$part"'" "$d" || exit 1
    m="$(ls "$d/EFI" | grep -ix microsoft | head -n1)"
    rc=0
    if [ -n "$m" ]; then nh_rsudo tar -C "$d/EFI" -cf - "$m" || rc=1; else rc=1; fi
    nh_rsudo umount "$d" 2>/dev/null
    rmdir "$d" 2>/dev/null
    exit $rc'
}

# nh_carry_install_remote <remote> <carry-tar> — unpack the carried
# EFI/Microsoft into /mnt/boot/EFI on the target, the ESP disko has
# just formatted and mounted. The --remote counterpart of the two
# `tar -xf` lines in nh_install_carry.
#
# The tar travels on the ssh session's stdin and lands in a file on the
# target before it is unpacked: nh_rsudo pipes the operator's password
# into sudo's own stdin, so `nh_rsudo tar -xf -` would read that pipe
# rather than the session (lib/ssh.sh).
nh_carry_install_remote() {
  local remote="$1" carry="$2"
  # shellcheck disable=SC2016 # runs on the TARGET's shell
  nh_ssh_sudo "$remote" --installer -- '
    t="$(mktemp)" || exit 1
    cat >"$t" || exit 1
    nh_rsudo install -d /mnt/boot/EFI && nh_rsudo tar -xf "$t" -C /mnt/boot/EFI
    rc=$?
    rm -f "$t"
    exit $rc' <"$carry"
}

# nh_disk_name <remote> <by-id> — the kernel name behind a by-id path,
# resolved on the target.
nh_disk_name() {
  nh_target_sh "$1" "basename \"\$(readlink -f '$2')\""
}

# nh_esp_guard <remote> <lsblk-json> <disk-name> — the second OS walk.
# The chosen disk's ESP holding another OS's loader means that OS
# stops booting when the disk is erased: name it and require a second
# explicit confirmation — unless it is Windows' loader and Windows
# lives on another disk, which the install carries across (see the
# header). A Windows ESP on a NON-target disk is left alone and gets
# the one line that lists it in systemd-boot's menu (the firmware
# menu boots it regardless).
nh_esp_guard() {
  local remote="$1" json="$2" target="$3" part entry other names="" carry
  local -a parts entries
  carry="$(nh_windows_carry "$remote" "$json" "$target")" || return 1
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
      if [ "$part" = "$carry" ] && printf '%s' "$entry" | grep -qix microsoft; then
        nh_info "the ESP /dev/$part holds Windows' boot files and Windows lives on another disk — they are carried into the new ESP, and systemd-boot lists Windows"
        continue
      fi
      nh_warn "the ESP /dev/$part on /dev/$target holds the boot files of $(nh_name_os "$entry") — that OS stops booting when this disk is erased; move it to an ESP on its own disk first"
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
      nixos)
        # A guest has no disk: it starts with its machine's deploy.
        [ -z "$(nh_host_machine "$name")" ] || continue
        rows="${rows}${name}	(reformat — erases its disk)
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

# nh_identity_key_file — the plaintext of the fleet's `identity` key,
# for the one journey that cannot use an ssh config: a remote
# installer's clone. A fleet machine holds it at ~/.ssh/identity
# (agenix, the operator's own); the installer ISO and a --keys seat
# open the ciphertext they carry (nh_clone_key).
nh_identity_key_file() {
  if [ -r "$HOME/.ssh/identity" ]; then
    printf '%s' "$HOME/.ssh/identity"
    return 0
  fi
  nh_clone_key && return 0
  nh_err "no identity key to clone with: ~/.ssh/identity is not readable here and no clone key is baked in"
  return 1
}

# nh_install_clone_remote <remote> <root> <sha> <dest> — the fleet on
# the installer at <sha>: the identity key into the installer's RAM
# (/root/.ssh on the ISO is a tmpfs, the same boundary the ISO's own
# unwrapped identity lives in), then a clone over it. The ISO pins the
# forge's host keys, so the clone verifies rather than asks.
nh_install_clone_remote() {
  local remote="$1" root="$2" sha="$3" dest="$4" key repo branch
  key="$(nh_identity_key_file)" || return 1
  repo="$(nh_fleet_repo)" || return 1
  branch="$(nh_fleet_branch "$root")" || return 1
  nh_info "cloning the fleet onto the installer at ${sha:0:12}"
  nh_ssh "$remote" --installer -- 'umask 077; mkdir -p /root/.ssh && cat >/root/.ssh/nixhold-identity' <"$key" || {
    nh_err "could not place the identity key on the installer"
    return 1
  }
  nh_ssh "$remote" --installer -- "rm -rf '$dest' && GIT_SSH_COMMAND='ssh -i /root/.ssh/nixhold-identity -o IdentitiesOnly=yes' git clone -q --branch '$branch' 'git@github.com:$repo.git' '$dest' && git -C '$dest' checkout -q '$sha'" </dev/null || {
    nh_err "the installer could not clone the fleet — it needs the forge reachable and its host key pinned (the fleet ISO pins github.com)"
    return 1
  }
}

# nh_install_carry <remote> <carry> — Windows' loader onto the new ESP.
nh_install_carry() {
  local remote="$1" carry="$2"
  if [ -z "$remote" ]; then
    nh_sudo install -d /mnt/boot/EFI && nh_sudo tar -xf "$carry" -C /mnt/boot/EFI
  else
    nh_carry_install_remote "$remote" "$carry"
  fi
}

# nh_install_stage_tree <remote> <dir> — <dir>'s tree (etc/ssh, the
# host key; etc/nixhold, the fleet key) into /mnt, owned by root with
# the modes staged here. Streamed as a tar: nh_rsudo pipes the
# operator's password into sudo's own stdin, so the remote side writes
# the stream to a file first (see nh_carry_install_remote).
nh_install_stage_tree() {
  local remote="$1" dir="$2" tarfile
  tarfile="$(nh_tmpdir stage)/tree.tar" || return 1
  tar -C "$dir" -cf "$tarfile" . || return 1
  if [ -z "$remote" ]; then
    nh_sudo tar -C /mnt --no-same-owner -xf "$tarfile"
  else
    # shellcheck disable=SC2016 # runs on the TARGET's shell
    nh_ssh_sudo "$remote" --installer -- '
      t="$(mktemp)" || exit 1
      cat >"$t" || exit 1
      nh_rsudo tar -C /mnt --no-same-owner -xf "$t"
      rc=$?
      rm -f "$t"
      exit $rc' <"$tarfile"
  fi
}

# nh_install_phases <name> <root> <remote> <facter> <carry> <hosts-file>
#                   <minted…> — the one phase sequence, in place
# (<remote> empty: the installer ISO) or over ssh to a booted
# installer. Everything that can fail or prompt — the required-secret
# walk ($EDITOR), opening the fleet key (a wrong passphrase, a token
# that never got touched), the commit and the push — runs BEFORE
# disko touches the disk. Reversed, a passphrase typo left the
# operator with a wiped machine and nothing installed on it.
#
# Called as `nh_install_phases … || rc=$?`, so errexit is off in here:
# every step is checked explicitly.
nh_install_phases() {
  local name="$1" root="$2" remote="$3" facter_target="$4" carry="$5" hosts_file="$6"
  shift 6
  local minted=("$@") extra keys_dir sha flake out

  # The tool belt the phases run on the target — baked into the ISO;
  # requiring it is what makes the sequence honest anywhere else.
  # shellcheck disable=SC2016 # runs on the TARGET's shell
  nh_target_sh "$remote" 'for c in disko nixos-facter nixos-install git nix; do command -v "$c" >/dev/null 2>&1 || { echo "missing on the installer: $c" >&2; exit 1; }; done' || {
    nh_err "the target is not a nixhold installer — boot the fleet ISO on it (disko, nixos-facter, nixos-install, git and nix ship on it)"
    return 1
  }

  # Before the disk is touched AND before the build, so a host
  # first-boots with every required secret decryptable.
  nh_provision_required_secrets "$name" nixos || {
    nh_err "secret provisioning failed — fix the secrets above, then re-run install (nothing has been erased)"
    return 1
  }

  # What the machine needs before its first activation, staged into a
  # tree that lands in /mnt/etc after disko: the fleet key (agenix
  # decrypts with it on the first pass — opened here over the
  # operator's route, discovered now at the cost of a re-run rather
  # than after disko at the cost of an erased machine) and a fresh ssh
  # host key, whose pubkey this commits as keys/hosts/<name>.pub.
  extra="$(nh_tmpdir extra-files)" || return 1
  mkdir -p "$extra/etc/ssh" || {
    nh_err "could not create the staging tree under $extra"
    return 1
  }
  nh_stage_host_key "$name" "$extra/etc/ssh" || return 1
  nh_fleet_key_install --stage "$extra" || {
    nh_err "the fleet key could not be staged — $name would first-boot unable to decrypt anything (nothing has been erased)"
    return 1
  }

  # The hardware report, off the target, before anything is written to
  # its disk: the build below reads it out of the committed tree.
  nh_info "generating the hardware report"
  if ! nh_target_sudo_sh "$remote" "nh_rsudo nixos-facter" >"$facter_target.tmp" || [ ! -s "$facter_target.tmp" ]; then
    rm -f "$facter_target.tmp"
    nh_err "nixos-facter failed on the target"
    return 1
  fi
  mv "$facter_target.tmp" "$facter_target" || return 1
  nh_ok "wrote $facter_target"

  # The tree the target builds: committed and pushed first, so the
  # sha the machine boots from is one the fleet repo holds.
  keys_dir="$(nh_worktree_keys_dir 2>/dev/null)" || keys_dir="$root/keys"
  nh_commit_paths "$root" "host($name): install (disk + facter)" \
    "$hosts_file" "$facter_target" "$keys_dir/hosts/$name.pub" \
    "${minted[@]+"${minted[@]}"}"
  sha="$(nh_fleet_rev "$root")" || return 1
  nh_fleet_push "$root" || return 1
  if [ -z "$remote" ]; then
    flake="$root"
  else
    flake="/root/nixhold-fleet"
    nh_install_clone_remote "$remote" "$root" "$sha" "$flake" || return 1
  fi

  nh_info "partitioning + mounting per $name's disko.devices"
  nh_target_sudo_sh "$remote" "nh_rsudo disko --mode destroy,format,mount --yes-wipe-all-disks --flake '$flake#$name'" || {
    nh_err "disko failed — nothing was installed"
    return 1
  }

  # Windows' loader, read off the old ESP before the format, onto the
  # new one before the closure is built beside it.
  if [ -n "$carry" ]; then
    nh_install_carry "$remote" "$carry" || {
      nh_err "could not put Windows' boot files onto the new ESP — the disk is already formatted, so re-run the install"
      return 1
    }
    nh_ok "carried Windows' boot files into the new ESP"
  fi

  nh_install_stage_tree "$remote" "$extra" || {
    nh_err "could not stage the host key and the fleet key into /mnt/etc"
    return 1
  }
  nh_ok "staged the host key and the fleet key into /mnt/etc"

  # Into the TARGET's store, not the installer's. The ISO's
  # /nix/store is an overlay whose writable layer is an unsized tmpfs
  # — half of RAM, whatever the disk being installed holds — and its
  # / is another one, so a closure built in place is capped by memory
  # and a graphical host's does not fit. `--store /mnt` is the chroot
  # store nixos-install builds into itself; `auto?trusted=1` keeps
  # the installer's own store a source, so what it already realised
  # is not re-fetched; TMPDIR moves build scratch off the RAM-backed
  # root. `env` rather than a prefix assignment: sudo resets the
  # environment. --print-out-paths reports the logical /nix/store
  # path even out of a chroot store, so nixos-install --system takes
  # it as-is and copies nothing.
  nh_info "building $name's system closure at ${sha:0:12} into $name's own store"
  out="$(nh_target_sudo_sh "$remote" "nh_rsudo install -d -m 1777 /mnt/tmp || exit 1
nh_rsudo env TMPDIR=/mnt/tmp nix build --no-link --print-out-paths --store /mnt --extra-substituters 'auto?trusted=1' '$flake#nixosConfigurations.$name.config.system.build.toplevel'")" || {
    nh_err "closure build failed"
    return 1
  }
  [ -n "$out" ] || {
    nh_err "the build printed no out path"
    return 1
  }

  nh_info "installing $out into /mnt"
  nh_target_sudo_sh "$remote" "nh_rsudo nixos-install --root /mnt --system '$out' --no-root-passwd" || {
    nh_err "nixos-install failed"
    return 1
  }
  nh_ok "installed $name"
  if [ -n "$remote" ]; then
    nh_info "rebooting the installer into $name"
    nh_ssh "$remote" --installer -- "reboot" </dev/null >/dev/null 2>&1 || true
  fi
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
# Set from the environment so the handover in nh_reexec_at_fleet_pin
# carries it: the child's clone step finds the checkout already in
# place and would otherwise skip the relocation.
_NH_BOOTSTRAPPED="${NIXHOLD_BOOTSTRAPPED:-0}"
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
    nh_mark_cloned
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

# nh_darwin_switch <out> — nix-darwin's switch from a built system
# (root, as nix-darwin requires; lib/system.sh). The first switch on a
# fresh Mac is refused when /etc holds files nix-darwin did not write
# (/etc/nix/nix.conf from the Nix installer, /etc/zshenv, …): those
# are moved to <file>.before-nix-darwin — the rename nix-darwin asks
# for — and the switch retried once.
nh_darwin_switch() {
  local out="$1" log attempt files f
  log="$(nh_tmpdir switch)/log" || return 1
  for attempt in 1 2; do
    if (nh_activate_darwin "$out" 2>&1 | tee "$log" >&2; exit "${PIPESTATUS[0]}"); then
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
  nh_err "activation failed — see above"
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
#   2. build — the system closure, as the operator, from the checkout
#      at its committed HEAD (a Mac that has never switched has no ssh
#      config to fetch the forge with, so the clone `--repo/--keys`
#      made is the source; ARCHITECTURE "Where a host is built"), then
#      activate as root, with the first-switch /etc refusal handled in
#      place;
#   3. secrets verified under /run/agenix, then a second activation so
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

  # 2. Build at the committed HEAD, then activate.
  local sha out
  sha="$(nh_fleet_rev "$root")" || return 1
  nh_fleet_push "$root" || return 1
  nh_info "building $name's system at ${sha:0:12}"
  out="$(sh -c "$(nh_build_cmd "$root" darwin "$name" 0)")" || {
    nh_err "could not build $name's system closure"
    return 1
  }
  nh_darwin_switch "$out" || return 1

  # 3. Secrets, then the .pub files.
  nh_darwin_wait_secrets "$name" || true
  if [ "$(nh_host_eval "$name" darwin nixhold.secrets | jq 'any(.[]; .sshKey and .active)')" = "true" ]; then
    nh_info "activating again so home-manager derives the .pub files of the SSH keys"
    nh_darwin_switch "$out" || return 1
  fi

  nh_ok "installed $name"
  nh_next_after_install "$name" darwin
}

# nh_next_after_install <name> <platform> — the closing steps for a
# machine that was just imaged.
#
# "once <name> is on the tailnet" named a condition without the command
# that reaches it, and which command that is, is declared: a host with
# `nixhold.services.tailscale.authKeySecret` joins on activation, one
# without joins by hand exactly once and nothing in the fleet will do
# it for the operator. So the verb reads the host rather than making
# the operator work out which case they are in (ARCHITECTURE
# "Walkthrough shape": end with the next command).
#
# nix-darwin has no auth-key file at all — modules/services/tailscale/
# darwin.nix asserts when one is set — so a Mac is always by hand, and
# it switches in place rather than rebooting.
nh_next_after_install() {
  local name="$1" platform="$2" ts="" enabled="false" key="" n=1
  ts="$(nh_host_eval "$name" "$platform" nixhold.services.tailscale 2>/dev/null)" || ts=""
  if [ -n "$ts" ]; then
    enabled="$(printf '%s' "$ts" | jq -r '.enable // false')"
    key="$(printf '%s' "$ts" | jq -r '.authKeySecret // empty')"
  fi

  nh_info "next:"
  if [ "$platform" != "darwin" ]; then
    printf '  %d. %s reboots into its new system.\n' "$n" "$name" >&2
    n=$((n + 1))
  fi
  if [ "$enabled" = "true" ] && [ -z "$key" ]; then
    if [ "$platform" = "darwin" ]; then
      printf '  %d. On this Mac, join the tailnet once (a Mac has no auth-key file):\n' "$n" >&2
    else
      printf '  %d. On %s itself — it declares no tailscale authKeySecret,\n     so it joins the tailnet by hand, once:\n' "$n" "$name" >&2
    fi
    printf '       sudo tailscale up\n' >&2
    n=$((n + 1))
  elif [ "$enabled" = "true" ]; then
    printf '  %d. %s joins the tailnet itself on activation (authKeySecret "%s").\n' "$n" "$name" "$key" >&2
    n=$((n + 1))
  fi
  printf '  %d. From here, for every change after this:\n       nixhold deploy %s\n' "$n" "$name" >&2
  if [ "$enabled" = "true" ] && [ -n "$key" ]; then
    printf '  A reinstall spends the committed key: if %s never appears, put a fresh\n' "$name" >&2
    printf "  one in with 'nixhold secret edit %s %s', then deploy.\n" "$name" "$key" >&2
  fi
}

cmd_host_install() {
  local name="" remote="" disk="" yes=0 picked=0 repo="" keys=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      # Each value flag reports its own missing value: left bare, "$2"
      # under `set -u` aborts the run with bash's "unbound variable".
      --remote)
        remote="${2:-}"
        [ -n "$remote" ] || { nh_err "--remote needs <user>@<ip>"; return 1; }
        shift 2 ;;
      --disk)
        disk="${2:-}"
        [ -n "$disk" ] || { nh_err "--disk needs a /dev/disk/by-id path"; return 1; }
        shift 2 ;;
      --yes) yes=1; shift ;;
      --repo)
        repo="${2:-}"
        [ -n "$repo" ] || { nh_err "--repo needs <owner/repo>"; return 1; }
        shift 2 ;;
      --keys)
        keys="${2:-}"
        [ -n "$keys" ] || { nh_err "--keys needs a directory"; return 1; }
        shift 2 ;;
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
  # Before any prompt and any write: if this run cloned the checkout,
  # the CLI that finishes the install is the one that checkout pins.
  nh_reexec_at_fleet_pin "$root"

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

  # A guest ("Guests") owns no disk and is never imaged: its machine's
  # deploy builds and starts it.
  local machine
  machine="$(nh_host_machine "$name" 2>/dev/null || true)"
  if [ -n "$machine" ]; then
    nh_err "$name is a guest of $machine — nothing to install; 'nixhold deploy $machine' builds and starts it"
    return 1
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
    nh_info "this machine is not the installer — $name installs over ssh to a target booted from the fleet ISO"
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

  # 1b. Windows' loader on the target's ESP, with Windows on another
  #     disk: read it now, while the old ESP exists. Both paths put it
  #     back into /mnt/boot/EFI right after disko, before the closure
  #     is built (nh_install_carry).
  local carry="" carry_part
  if [ -n "$disk" ]; then
    local cjson cname
    cjson="$(nh_disk_json "$remote")" || cjson=""
    cname="$(nh_disk_name "$remote" "$disk" 2>/dev/null)" || cname=""
    carry_part=""
    if [ -n "$cjson" ] && [ -n "$cname" ]; then
      carry_part="$(nh_windows_carry "$remote" "$cjson" "$cname")" || return 1
    fi
    if [ -n "$carry_part" ]; then
      carry="$(nh_tmpdir esp-carry)/microsoft.tar" || return 1
      if ! nh_esp_tar "$remote" "$carry_part" >"$carry" || [ ! -s "$carry" ]; then
        nh_err "could not read Windows' boot files off /dev/$carry_part — nothing has been erased"
        return 1
      fi
      nh_ok "read Windows' boot files off /dev/$carry_part; they return to the new ESP after the format"
    fi
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

  # 2b. The tailnet node of this name, and the auth key that replaces
  #     it. Before the disk is touched and before the required-secret
  #     walk below, so the walk finds the ciphertext already there:
  #     the machine is about to be wiped, so its live node is stale and
  #     its committed key is spent (see "The tailnet's API client").
  #     A fleet that commits no API client for the host's network
  #     writes nothing here and the walk asks for a pasted key, as
  #     before; darwin never reaches this, having no auth-key file.
  local minted=() minted_out m
  minted_out="$(nh_tailnet_remint "$name" nixos --delete-node)" || {
    nh_err "could not re-mint $name's tailnet auth key — nothing has been erased"
    return 1
  }
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    minted+=("$m")
  done <<<"$minted_out"

  local rc=0
  nh_install_phases "$name" "$root" "$remote" "$facter_target" "$carry" "$hosts_file" \
    "${minted[@]+"${minted[@]}"}" || rc=$?
  [ "$rc" -eq 0 ] && nh_next_after_install "$name" "$platform"
  return "$rc"
}
