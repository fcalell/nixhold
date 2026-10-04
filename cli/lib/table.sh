# Tables: every listing the CLI prints goes through nh_table, so they
# all read the same way. gum is not the renderer: its `table --print`
# ignores the terminal width, so a long description runs off the edge.

# nh_table [--color <col>[,<col>…]] — TSV on stdin into a rounded box.
# The first line is the header. A line that starts with \036 (ASCII RS)
# is a section: a rule across the box naming it, for a table grouped by
# one column's value. Every column is as wide as its widest cell. On a
# terminal the last column is cut with … so the box fits the screen,
# the header is bold, the borders dim, and each --color column's cells
# are colored by their state word; piped, every cell is whole and no
# escape is written, since a pipe reads the data rather than the
# screen.
nh_table() {
	local color="" cols=0 tty=0
	while [ "$#" -gt 0 ]; do
		case "$1" in
			--color)
				color="$2"
				shift 2
				;;
			*)
				nh_err "nh_table: unknown argument $1"
				return 1
				;;
		esac
	done
	if [ -t 1 ]; then
		cols="$(stty size </dev/tty 2>/dev/null | cut -d' ' -f2)" || cols=""
		cols="${cols:-${COLUMNS:-0}}"
		[ -n "${NO_COLOR:-}" ] || tty=1
	fi
	# A UTF-8 locale makes awk count characters, not bytes: the box
	# drawing and the ellipsis are three bytes each.
	LC_ALL=C.UTF-8 awk -F'\t' -v cols="$cols" -v tty="$tty" -v color="$color" '
    function rep(s, n,   r) { r = ""; while (n-- > 0) r = r s; return r }
    function paint(code, s) { return tty ? "\033[" code "m" s "\033[0m" : s }
    # The state words the CLI prints, by what they ask of the operator:
    # green is done, yellow wants a look, red blocks something.
    function state(s) {
      if (s ~ /^(provisioned|present|enabled|ok|clean|up to date)$/) return "32"
      if (s ~ /^(missing|eval-err|failed)/ || s ~ /(diverged|unreachable)/) return "31"
      if (s ~ /^(ahead|behind|no upstream|\(detached\)|[0-9]+ dirty)/) return "33"
      if (s ~ /^(optional|disabled|-)$/) return "2"
      return ""
    }
    function cell(s, w, c,   code) {
      if (length(s) > w) s = substr(s, 1, w - 1) "…"
      code = (c in colored) ? state(s) : ""
      s = s rep(" ", w - length(s))
      return code == "" ? s : paint(code, s)
    }
    function rule(l, m, r,   i, s) {
      s = l
      for (i = 1; i <= n; i++) s = s rep("─", w[i] + 2) (i < n ? m : r)
      return paint("2", s)
    }
    function section(t,   inner) {
      inner = total - 2
      t = "─ " t " "
      if (length(t) > inner) t = substr(t, 1, inner)
      return paint("2", "├" t rep("─", inner - length(t)) "┤")
    }
    function row(r, bold,   i, f, s, bar) {
      split(r, f, "\t")
      bar = paint("2", "│")
      s = bar
      for (i = 1; i <= n; i++) {
        s = s " " (bold ? paint("1", sprintf("%-" w[i] "s", f[i])) : cell(f[i], w[i], i)) " " bar
      }
      return s
    }
    BEGIN { m = split(color, cc, ","); for (i = 1; i <= m; i++) colored[cc[i]] = 1 }
    NR == 1 { n = NF }
    { line[NR] = $0 }
    substr($0, 1, 1) != "\036" {
      for (i = 1; i <= n; i++) if (length($i) > w[i]) w[i] = length($i)
    }
    END {
      if (NR == 0) exit
      total = 1
      for (i = 1; i <= n; i++) total += w[i] + 3
      # Only the last column gives: it is the free text (a description,
      # a note), and every column before it is a key the eye scans.
      if (cols > 0 && total > cols) {
        split(line[1], h, "\t")
        min = length(h[n])
        if (min < 8) min = 8
        cut = total - cols
        if (w[n] - cut < min) cut = w[n] - min
        if (cut > 0) { w[n] -= cut; total -= cut }
      }
      print rule("╭", "┬", "╮")
      print row(line[1], 1)
      if (NR > 1 && substr(line[2], 1, 1) != "\036") print rule("├", "┼", "┤")
      for (k = 2; k <= NR; k++) {
        if (substr(line[k], 1, 1) == "\036") print section(substr(line[k], 2))
        else print row(line[k], 0)
      }
      print rule("╰", "┴", "╯")
    }
  '
}

# nh_table_section <title> — the line nh_table draws as a section rule.
nh_table_section() {
	printf '\036%s\n' "$1"
}
