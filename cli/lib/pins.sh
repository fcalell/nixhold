# Pins: upstream releases pinned by a committed manifest (ARCHITECTURE
# "Pins"). The declarations are read off each host's `nixhold.pins`
# and unioned by name; a pin's file is re-rooted from the flake's
# store copy to the worktree, since `update` writes it there.

# nh_host_pins <host> <platform> — the host's declarations as JSON:
# { <name>: { file, latest, manifest } }, `file` as the store path
# string the option evaluates to. `value` is never read here: the
# declaration must evaluate before the file exists.
nh_host_pins() {
  local host="$1" platform="$2" root set
  root="$(nh_fleet_root)" || return 1
  set="$(nh_config_set "$platform")" || return 1
  nix eval --json --no-warn-dirty "$root#$set.$host" --apply '
    h: builtins.mapAttrs (_: p: { file = toString p.file; inherit (p) latest manifest; }) h.config.nixhold.pins'
}

# nh_fleet_pins — every host's declarations unioned by name, memoised
# for the process like the fleet view. Non-zero, naming them, when a
# name is declared with different fields on two hosts: the file is
# one, so the declaration must be.
nh_fleet_pins() {
  local root memo line host platform decls conflicts
  root="$(nh_tmp_root)" || return 1
  memo="$root/pins.json"
  if [ -s "$memo" ]; then
    cat "$memo"
    return 0
  fi
  decls="$root/pins.hosts.json"
  : >"$decls"
  while IFS= read -r line; do
    host="${line%% *}"
    platform="${line##* }"
    [ -n "$host" ] || continue
    nh_host_pins "$host" "$platform" >>"$decls" || {
      nh_err "could not read nixhold.pins of $host"
      return 1
    }
    printf '\n' >>"$decls"
  done < <(nh_hosts)
  conflicts="$(jq -s -r '
    [ .[] | to_entries[] ] | group_by(.key)
    | map(select((map(.value) | unique | length) > 1) | .[0].key) | .[]' "$decls")"
  if [ -n "$conflicts" ]; then
    nh_err "a pin is declared with different fields on two hosts: $(printf '%s' "$conflicts" | tr '\n' ' ')"
    return 1
  fi
  jq -s 'add // {}' "$decls" >"$memo" || return 1
  cat "$memo"
}

# nh_pin_file <name> <evaluated-path> — the worktree path of a pin's
# file; exit 3 when it lies outside the fleet checkout.
nh_pin_file() {
  nh_reroot "nixhold.pins.$1.file" "$2"
}

# nh_pin_version <file> — the version a pin file carries; empty when
# the file is absent or is not a manifest.
nh_pin_version() {
  [ -f "$1" ] || return 0
  jq -r '.version // empty' "$1" 2>/dev/null || true
}

# nh_pin_fetch <name> <latest-url> <manifest-template> <out> — the
# manifest at the version `latest` names, written to <out>; that
# version on stdout. A manifest whose `.version` is another string is
# refused: the two endpoints disagree, and a file carrying a version
# other than the one it was fetched at is what the next run reads.
nh_pin_fetch() {
  local name="$1" latest="$2" template="$3" out="$4" version url got
  version="$(curl -fsSL --max-time 60 "$latest")" || {
    nh_err "pin $name: could not read $latest"
    return 1
  }
  version="$(printf '%s' "$version" | tr -d '[:space:]')"
  if [ -z "$version" ]; then
    nh_err "pin $name: $latest answered no version"
    return 1
  fi
  url="${template//\$\{version\}/$version}"
  curl -fsSL --max-time 120 -o "$out" "$url" || {
    nh_err "pin $name: could not fetch $url"
    return 1
  }
  got="$(jq -r '.version // empty' "$out" 2>/dev/null)" || got=""
  if [ "$got" != "$version" ]; then
    nh_err "pin $name: $url carries version '${got:-none}', $latest says '$version'"
    return 1
  fi
  printf '%s' "$version"
}
