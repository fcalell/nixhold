# nixhold repo pull
#
# Every checkout on this machine meets its forge (ARCHITECTURE "nixhold
# repo"): fetched at once, then each synced the way the fleet verbs
# sync the fleet (nh_checkout_sync), dirty allowed — the ones behind
# fast-forward, and a refusal comes with its offer on a terminal
# (rebase a diverged branch; commit, then rebase, where the
# fast-forward touches an edited file). A checkout that is missing,
# detached or has no upstream has nothing to pull and is only named.
# One failure never stops the rest; the verb fails when any did.

cmd_repo_pull() {
	case "${1:-}" in
		"") ;;
		-h | --help)
			echo "Usage: nixhold repo pull"
			return 0
			;;
		*)
			nh_err "unknown argument: $1"
			return 1
			;;
	esac
	nh_require_cmd git || return 1
	local rows tmp name path failed=()
	rows="$(nh_checkouts)" || return 1
	tmp="$(nh_tmpdir repo)" || return 1
	nh_checkouts_fetch "$tmp" <<<"$rows"
	# The rows ride fd 3: stdin stays the terminal the offers ask on.
	while IFS=$'\t' read -r name path <&3; do
		if ! nh_checkout_present "$path"; then
			nh_info "$name: missing — its clone unit has not run"
			continue
		fi
		if ! git -C "$path" symbolic-ref -q HEAD >/dev/null ||
			! git -C "$path" rev-parse -q --verify '@{u}' >/dev/null 2>&1; then
			nh_info "$name: detached or no upstream — nothing to pull"
			continue
		fi
		if [ "$(cat "$tmp/$name.rc")" != 0 ]; then
			nh_err "$name: could not fetch — the forge is unreachable"
			failed+=("$name")
			continue
		fi
		nh_checkout_sync "$path" --allow-dirty --fetched || failed+=("$name")
	done 3<<<"$rows"
	if [ "${#failed[@]}" -gt 0 ]; then
		nh_err "not pulled: ${failed[*]}"
		return 1
	fi
	nh_ok "every checkout is on its forge's tip"
}
