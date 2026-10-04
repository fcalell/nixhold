# nixhold repo [status]
#
# Every checkout on this machine (ARCHITECTURE "nixhold repo"): the
# fleet, then the host's declared repositories, fetched at once and
# printed one line each — the branch, where it stands against its
# upstream, the dirty count, or why there is nothing to compare. A
# forge that could not be reached marks its line and fails the verb.

cmd_repo_status() {
	case "${1:-}" in
		"") ;;
		-h | --help)
			echo "Usage: nixhold repo [status]"
			return 0
			;;
		*)
			nh_err "unknown argument: $1"
			return 1
			;;
	esac
	nh_require_cmd git || return 1
	local rows tmp name path rc=0 fetch table="" row
	rows="$(nh_checkouts)" || return 1
	tmp="$(nh_tmpdir repo)" || return 1
	nh_checkouts_fetch "$tmp" <<<"$rows"
	while IFS=$'\t' read -r name path; do
		fetch="$(cat "$tmp/$name.rc" 2>/dev/null || echo -)"
		row="$(nh_checkout_line "$name" "$path" "$fetch")" || rc=1
		table="$table$row"$'\n'
		case "$fetch" in 0 | -) ;; *) rc=1 ;; esac
	done <<<"$rows"
	{
		printf 'CHECKOUT\tBRANCH\tSYNC\tTREE\n'
		printf '%s' "$table"
	} | nh_table --color 2,3,4
	return "$rc"
}
