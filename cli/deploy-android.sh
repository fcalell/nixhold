# nixhold deploy — the Android branch (ARCHITECTURE "Android hosts").
# Sourced by deploy.sh.
#
# An Android host has no closure. Its build product is the plan —
# `androidConfigurations.<system>.<name>.config.system.build.plan`,
# one JSON of everything declared with each APK's store path, id,
# version and hash — and deploying is converging the device onto it
# over adb: every surface is read before it is written, only the
# difference is applied, one line per change, and a device that
# already matches is not touched. N adb calls, not an atomic switch:
# a failure midway leaves the device between two plans and the next
# run continues from there.

# nh_android_deploy <name> <dry-run> <target>
nh_android_deploy() {
  local name="$1" dry_run="$2" target="$3" root system plan serial
  root="$(nh_fleet_root)" || return 1
  nh_require_cmd adb jq
  system="$(nh_system)" || return 1
  nh_info "building the plan for $name (fetches its APKs)"
  plan="$(nix build --no-link --print-out-paths --no-warn-dirty \
    "$root#androidConfigurations.$system.$name.config.system.build.plan")" || return 1

  nh_android_key || return 1
  serial="$(nh_android_device "$name" "$target")" || return 1
  nh_android_authorized "$serial" || return 1
  nh_android_converge "$serial" "$plan" "$dry_run"
}

# nh_android_key — the fleet's `adb` secret, decrypted into the
# scratch root and handed to adb as ADB_VENDOR_KEYS. adb reads vendor
# keys when its server starts, so a server an earlier shell left
# running is replaced by one that holds this key. adb's own
# ~/.android/adbkey is offered too; the device accepts whichever it
# consented to.
nh_android_key() {
  local sdir src dir out
  sdir="$(nh_worktree_secrets_dir)" || return 1
  src="$sdir/adb.age"
  if [ ! -f "$src" ]; then
    nh_err "no ciphertext for the adb key at $src — nixhold secret edit adb"
    return 1
  fi
  dir="$(nh_tmpdir adb)" || return 1
  out="$dir/adbkey"
  nh_age_decrypt "$src" "$out" || return 1
  chmod 600 "$out" || return 1
  export ADB_VENDOR_KEYS="$out"
  adb kill-server >/dev/null 2>&1 || true
  adb start-server >/dev/null 2>&1 || {
    nh_err "adb could not start its server"
    return 1
  }
}

# nh_android_device <name> <target> — the adb serial deploy drives, on
# stdout. In order: --target (an address), the roster's `serial` (a
# USB device, attached now), the tailnet address (connected), and when
# none answers the picker over what adb sees right now.
nh_android_device() {
  local name="$1" target="$2" serial addr
  if [ -n "$target" ]; then
    nh_android_connect "$target"
    return $?
  fi
  serial="$(nh_host_field "$name" serial)"
  if [ -n "$serial" ]; then
    if nh_android_attached "$serial"; then
      printf '%s' "$serial"
      return 0
    fi
    nh_warn "$name (USB serial $serial) is not attached"
  else
    addr="$(nh_deploy_addr "$name")"
    if [ -n "$addr" ]; then
      if serial="$(nh_android_connect "$addr" 2>/dev/null)"; then
        printf '%s' "$serial"
        return 0
      fi
      nh_warn "$name does not answer adb at $addr"
    fi
  fi
  nh_android_pick "$name"
}

# nh_android_connect <addr[:port]> — `adb connect`, port 5555 (network
# debugging) unless given; the serial adb knows it by (`addr:port`)
# on stdout.
nh_android_connect() {
  local addr="$1" out
  case "$addr" in
    *:*) ;;
    *) addr="$addr:5555" ;;
  esac
  out="$(adb connect "$addr" 2>&1)" || true
  case "$out" in
    *"connected to"*)
      printf '%s' "$addr"
      ;;
    *)
      nh_err "adb: $out"
      return 1
      ;;
  esac
}

# nh_android_attached <serial> — adb lists it, in any state.
nh_android_attached() {
  adb devices | awk -v s="$1" 'NR > 1 && $1 == s { found = 1 } END { exit !found }'
}

# nh_android_pick <name> — the operator picks among what adb sees: USB
# devices (`adb devices -l`) and the LAN's mDNS advertisements (`adb
# mdns services`; a device with network debugging on advertises). A
# USB pick is written to the roster as `serial`, the way `host
# install` writes `disk`: the picker's output, never the operator's
# input. A network pick is connected and not written — an ip:port is
# a lease, not an identity.
nh_android_pick() {
  local name="$1" rows choice serial root hosts_file
  if ! nh_tty; then
    nh_err "nothing reaches $name — attach it over USB, or pass --target <addr>"
    return 1
  fi
  nh_info "devices adb sees now (USB, and the LAN over mDNS)"
  rows="$(nh_android_seen)"
  if [ -z "$rows" ]; then
    nh_err "adb sees no device — is USB debugging on, or network debugging on a device on this LAN?"
    return 1
  fi
  choice="$(printf '%s\n' "$rows" | gum choose --header "Which device is $name?")" || return 1
  serial="${choice%%	*}"
  case "$serial" in
    *:*)
      nh_android_connect "$serial"
      ;;
    *)
      root="$(nh_fleet_root)" || return 1
      hosts_file="$(nh_worktree_layout_file hostsFile)" || return 2
      nh_set_host_field "$hosts_file" "$name" serial "$serial" || return 1
      nh_stage_for_eval "$root" "$hosts_file"
      nh_fleet_view_reset
      nh_ok "wrote serial = \"$serial\" for $name into $hosts_file"
      printf '%s' "$serial"
      ;;
  esac
}

# nh_android_seen — "<serial>\t<what it is>" per line: attached
# devices first (USB, or already connected), then what mDNS advertises
# as ip:port. The pairing service of Android 11+ wireless debugging is
# left out: it takes a code, not a connection.
nh_android_seen() {
  adb devices -l | awk '
    NR > 1 && NF >= 2 && $1 !~ /^\*/ {
      model = ""
      for (i = 3; i <= NF; i++) if ($i ~ /^model:/) model = substr($i, 7)
      printf "%s\t%s %s\n", $1, model, $2
    }'
  if adb mdns check >/dev/null 2>&1; then
    adb mdns services 2>/dev/null | awk -F'\t' '
      NR > 1 && NF == 3 && $2 != "_adb-tls-pairing._tcp" { printf "%s\t%s (%s)\n", $3, $1, $2 }'
  fi
}

# nh_android_authorized <serial> — wait for the device to accept the
# key: the first connection puts a consent dialog on its screen.
nh_android_authorized() {
  local serial="$1" i state
  for i in $(seq 1 60); do
    state="$(adb -s "$serial" get-state 2>/dev/null || true)"
    [ "$state" = "device" ] && return 0
    [ "$i" -eq 1 ] && nh_info "waiting for $serial — accept this computer on the device's screen (tick 'Always allow'), and press nothing else"
    sleep 2
  done
  nh_err "$serial did not authorize this key in two minutes"
  return 1
}

# nh_adb <serial> <cmd…> — one `adb shell`, CRs stripped (adbd on
# older devices writes CRLF).
nh_adb() {
  local serial="$1"
  shift
  adb -s "$serial" shell "$@" | tr -d '\r'
}

# nh_android_component <package/class> — the fully qualified form
# Android prints back (`pkg/.Cls` is `pkg/pkg.Cls`).
nh_android_component() {
  local c="$1"
  case "$c" in
    */.*) printf '%s/%s.%s' "${c%%/*}" "${c%%/*}" "${c#*/.}" ;;
    *) printf '%s' "$c" ;;
  esac
}

_NH_ANDROID_CHANGES=0
# nh_android_apply <dry-run> <label> <cmd…> — one change: named in a
# dry run, applied otherwise. adb's shell commands report a failure
# in their output as often as in their exit status.
nh_android_apply() {
  local dry="$1" label="$2" out
  shift 2
  _NH_ANDROID_CHANGES=$((_NH_ANDROID_CHANGES + 1))
  if [ "$dry" -eq 1 ]; then
    nh_info "would: $label"
    return 0
  fi
  if ! out="$("$@" 2>&1)" || printf '%s' "$out" | grep -qE 'Failure|Error:|error:'; then
    nh_err "failed: $label"
    printf '%s\n' "$out" | sed 's/^/    /' >&2
    return 1
  fi
  nh_ok "$label"
}

# nh_android_converge <serial> <plan> <dry-run> — read each surface,
# apply the difference. Packages before the launcher and the owner,
# which name apps the packages put there.
nh_android_converge() {
  local serial="$1" plan="$2" dry="$3" rc=0 want cur
  _NH_ANDROID_CHANGES=0

  want="$(jq -r '.hostName' "$plan")"
  cur="$(nh_adb "$serial" settings get global device_name)"
  [ "$cur" = "$want" ] ||
    nh_android_apply "$dry" "device_name: $cur → $want" adb -s "$serial" shell settings put global device_name "$want" || rc=1

  local id ver apk sha path have
  while IFS=$'\t' read -r id ver apk sha; do
    path="$(nh_adb "$serial" pm path "$id" 2>/dev/null | sed -n 's/^package://p' | grep '/base\.apk$' | head -n1)" || path=""
    have=""
    [ -n "$path" ] && have="$(nh_adb "$serial" sha256sum "$path" | cut -d' ' -f1)"
    [ "$have" = "$sha" ] ||
      nh_android_apply "$dry" "install $id $ver" adb -s "$serial" install -r "$apk" || rc=1
  done < <(jq -r '.packages[] | [ .id, .versionName, .apk, .sha256 ] | @tsv' "$plan")

  local present
  present="$(nh_adb "$serial" pm list packages | sed 's/^package://')"
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    printf '%s\n' "$present" | grep -qx -- "$id" || continue
    nh_android_apply "$dry" "remove $id" adb -s "$serial" shell pm uninstall -k --user 0 "$id" || rc=1
  done < <(jq -r '.removedPackages[]' "$plan")

  local ns key val
  while IFS=$'\t' read -r ns key val; do
    cur="$(nh_adb "$serial" settings get "$ns" "$key")"
    [ "$cur" = "$val" ] ||
      nh_android_apply "$dry" "settings $ns $key: $cur → $val" adb -s "$serial" shell settings put "$ns" "$key" "$val" || rc=1
  done < <(jq -r '.settings | to_entries[] | .key as $ns | .value | to_entries[] | [ $ns, .key, .value ] | @tsv' "$plan")

  want="$(jq -r '.launcher // empty' "$plan")"
  if [ -n "$want" ]; then
    cur="$(nh_adb "$serial" cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME | tail -n1)"
    [ "$cur" = "$(nh_android_component "$want")" ] ||
      nh_android_apply "$dry" "launcher: $cur → $want" adb -s "$serial" shell cmd package set-home-activity "$want" || rc=1
  fi

  want="$(jq -r '.deviceOwner // empty' "$plan")"
  if [ -n "$want" ]; then
    cur="$(nh_adb "$serial" dumpsys device_policy | sed -n '/Device Owner/,/^$/p' | sed -n 's/.*ComponentInfo{\([^}]*\)}.*/\1/p' | head -n1)"
    if [ -z "$cur" ]; then
      nh_android_apply "$dry" "device owner: $want" adb -s "$serial" shell dpm set-device-owner "$want" || rc=1
    elif [ "$cur" != "$(nh_android_component "$want")" ]; then
      nh_err "device owner is $cur, not $want — Android changes an owner only through a factory reset"
      rc=1
    fi
  fi

  if [ "$_NH_ANDROID_CHANGES" -eq 0 ]; then
    nh_ok "$serial matches its plan — nothing to change"
  elif [ "$dry" -eq 1 ]; then
    nh_info "$_NH_ANDROID_CHANGES change(s) — dry run, nothing applied"
  fi
  return "$rc"
}
