# nixhold repo commit
#
# A walk over the dirty checkouts on this machine (ARCHITECTURE
# "nixhold repo"): for each, its short status, a yes, then the message
# in $EDITOR — starting from the draft hook's (programs.nixhold.repo.
# draft) when one is set. A yes commits the whole tree. A no or an
# empty message skips it. Nothing is pushed: that is `nixhold repo
# push`.

cmd_repo_commit() {
	case "${1:-}" in
		"") ;;
		-h | --help)
			echo "Usage: nixhold repo commit"
			return 0
			;;
		*)
			nh_err "unknown argument: $1"
			return 1
			;;
	esac
	nh_require_cmd git || return 1
	nh_tty || {
		nh_err "repo commit asks for each message — run it on a terminal"
		return 1
	}
	local rows name path dirty=0 committed=0
	rows="$(nh_checkouts)" || return 1
	# The rows ride fd 3: stdin stays the terminal the walk asks on.
	while IFS=$'\t' read -r name path <&3; do
		nh_checkout_present "$path" || continue
		[ -n "$(git -C "$path" status --porcelain)" ] || continue
		dirty=$((dirty + 1))
		nh_info "$name"
		if nh_checkout_commit "$path"; then committed=$((committed + 1)); fi
	done 3<<<"$rows"
	if [ "$dirty" -eq 0 ]; then
		nh_info "every checkout is clean"
	elif [ "$committed" -gt 0 ]; then
		nh_info "next: nixhold repo push"
	fi
}
