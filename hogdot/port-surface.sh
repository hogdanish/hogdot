#!/usr/bin/env bash
# Derive the WebGPU port surface: classify every file GodotWebGPU touches by how
# hard it is to bring onto the mainline release hogdot tracks.
#
# Nothing here is checked in as data on purpose — a stale ledger is worse than no
# ledger. Re-run this instead; it is exact and takes about a second.
#
# Classification (against $HOGDOT_UPSTREAM_BASE):
#   additive  — GodotWebGPU adds a path mainline does not have. Applies cleanly.
#   collision — GodotWebGPU adds a path mainline NOW ALSO has. Needs a decision.
#   clean     — GodotWebGPU modifies a file mainline has not touched since the
#               fork point. Applies cleanly.
#   conflict  — GodotWebGPU modifies a file mainline ALSO changed. This is the
#               real integration surface: the only files needing human judgement.
set -euo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
source "$here/refs.env"

BASE="$HOGDOT_UPSTREAM_BASE"
WEBGPU="$HOGDOT_WEBGPU_REF"
FORK="$HOGDOT_WEBGPU_FORK_POINT"

usage() {
	cat <<-EOF
		usage: ${0##*/} [--summary|--conflicts|--clean|--additive|--collisions|--all]

		  --summary     counts only (default)
		  --conflicts   the real integration surface, with churn on both sides
		  --clean       fork-modified files mainline has not touched
		  --additive    fork-added paths (top-level rollup)
		  --collisions  fork-added paths that now also exist upstream
		  --all         every section

		refs: base=$BASE  webgpu=$WEBGPU  fork-point=$FORK
	EOF
}

for ref in "$BASE" "$WEBGPU" "$FORK"; do
	git rev-parse --verify --quiet "$ref^{commit}" >/dev/null || {
		echo "error: ref '$ref' not found. Run: git fetch --all" >&2
		exit 1
	}
done

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# --no-renames keeps both name lists literal so the set intersection below is
# sound. With rename detection on, a file mainline renamed would appear under its
# new name upstream and its old name in the fork delta, and silently drop out of
# the conflict set.
git diff --no-renames --name-status "$FORK" "$WEBGPU" >"$tmp/fork-delta"
git diff --no-renames --name-only "$FORK" "$BASE" | sort >"$tmp/upstream-churn"

awk '$1 == "M" { print $2 }' "$tmp/fork-delta" | sort >"$tmp/fork-mod"
awk '$1 == "A" { print $2 }' "$tmp/fork-delta" | sort >"$tmp/fork-add"
awk '$1 == "D" { print $2 }' "$tmp/fork-delta" | sort >"$tmp/fork-del"

comm -12 "$tmp/fork-mod" "$tmp/upstream-churn" >"$tmp/conflicts"
comm -23 "$tmp/fork-mod" "$tmp/upstream-churn" >"$tmp/clean"

# A fork-added path that mainline has since grown itself needs an explicit call
# on which copy wins; it is not a free apply.
: >"$tmp/collisions"
while IFS= read -r f; do
	git cat-file -e "$BASE:$f" 2>/dev/null && printf '%s\n' "$f" >>"$tmp/collisions"
done <"$tmp/fork-add"
comm -23 "$tmp/fork-add" "$tmp/collisions" >"$tmp/additive"

churn() { # ref-a ref-b path -> "+N/-N"
	git diff --numstat "$1" "$2" -- "$3" | awk '{ printf "+%s/-%s", $1, $2 }'
}

show_summary() {
	printf '\n  hogdot port surface   %s  <-  %s\n' "$BASE" "$WEBGPU"
	printf '  (fork point %s)\n\n' "$FORK"
	printf '    %-38s %6d\n' "additive (apply wholesale)" "$(wc -l <"$tmp/additive")"
	printf '    %-38s %6d\n' "collisions (decide which copy wins)" "$(wc -l <"$tmp/collisions")"
	printf '    %-38s %6d\n' "clean modifications (apply as-is)" "$(wc -l <"$tmp/clean")"
	printf '    %-38s %6d  <-- the real work\n' "CONFLICTS (hand-port)" "$(wc -l <"$tmp/conflicts")"
	printf '    %-38s %6d\n' "deletions" "$(wc -l <"$tmp/fork-del")"
	printf '    %-38s %6d\n' "total files touched by the fork" "$(wc -l <"$tmp/fork-delta")"
	printf '\n'
}

show_conflicts() {
	printf '\n== CONFLICTS: %s modifies these AND mainline moved them ==\n\n' "$WEBGPU"
	printf '  %-64s %10s %12s\n' "FILE" "FORK" "MAINLINE"
	while IFS= read -r f; do
		printf '  %-64s %10s %12s\n' "$f" "$(churn "$FORK" "$WEBGPU" "$f")" "$(churn "$FORK" "$BASE" "$f")"
	done <"$tmp/conflicts"
	printf '\n'
}

show_clean() {
	printf '\n== CLEAN: fork-modified, mainline untouched since %s ==\n\n' "$FORK"
	sed 's/^/  /' "$tmp/clean"
	printf '\n'
}

show_additive() {
	printf '\n== ADDITIVE: new paths, rolled up two levels deep ==\n\n'
	awk -F/ '{ print (NF > 2 ? $1 "/" $2 : $0) }' "$tmp/additive" |
		sort | uniq -c | sort -rn | sed 's/^/  /'
	printf '\n'
}

show_collisions() {
	printf '\n== COLLISIONS: fork adds a path %s already has ==\n\n' "$BASE"
	if [ -s "$tmp/collisions" ]; then
		sed 's/^/  /' "$tmp/collisions"
	else
		printf '  (none)\n'
	fi
	printf '\n'
}

case "${1:---summary}" in
--summary) show_summary ;;
--conflicts) show_conflicts ;;
--clean) show_clean ;;
--additive) show_additive ;;
--collisions) show_collisions ;;
--all)
	show_summary
	show_conflicts
	show_clean
	show_collisions
	show_additive
	;;
-h | --help) usage ;;
*)
	usage >&2
	exit 2
	;;
esac
