#!/usr/bin/env bash
# pretooluse (Bash): enforce .claude/rules/port-provenance.md on port commits.
#
# The rule is the most important convention in this repo — every ported line must be
# traceable to the GodotWebGPU commit it came from, or the next rebase-forward cannot
# tell a WebGPU change from an upstream one. Prose is a request; this is the guarantee.
#
# Two failure modes are caught:
#   1. a `port(...)` commit with no Webgpu-Port:/Webgpu-Source: trailers
#   2. a Webgpu-Source: SHA that does not resolve, or resolves OUTSIDE the fork range
#      — i.e. fabricated provenance, which is worse than none because it looks right
#
# Deliberately narrow to stay noise-free: it only inspects commits whose message is
# visible on the command line (`-m`). A `-F file` or editor commit is skipped rather
# than guessed at. Exit 2 blocks the call and returns stderr to Claude.
set -uo pipefail

input="$(cat)"
command="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)"
[ -n "$command" ] || exit 0

# only git commits carrying an inline message
case "$command" in
*git*commit*) ;;
*) exit 0 ;;
esac
printf '%s' "$command" | grep -qE '(^|[[:space:]])-m([[:space:]]|=)' || exit 0

has_trailer=0
printf '%s' "$command" | grep -q 'Webgpu-Port:' && has_trailer=1

# a conventional-commit `port(scope):` subject is the marker for "this carries fork code"
is_port=0
printf '%s' "$command" | grep -qE '\bport\([a-z0-9._/-]+\)!?:' && is_port=1

if [ "$is_port" -eq 1 ] && [ "$has_trailer" -eq 0 ]; then
	cat >&2 <<-'EOF'
		BLOCKED — port commit is missing its provenance trailers (.claude/rules/port-provenance.md).

		Every port commit must end with the slice name and the upstream SHAs it carries:

		    Webgpu-Port: rd-core
		    Webgpu-Source: f8b3cd0 04713ba 137a252

		Find the SHAs for a path with:
		    git log --oneline 4.6.2-stable..webgpu/webgpu-4.6.2 -- <path>

		Also append the matching entry to .claude/skills/port/references/slice-log.md
		in this same change — including anything deliberately dropped.
	EOF
	exit 2
fi

[ "$has_trailer" -eq 1 ] || exit 0

# --- validate every cited SHA actually exists in the fork range -----------------
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
[ -f "$here/hogdot/refs.env" ] || exit 0
# shellcheck source=/dev/null
. "$here/hogdot/refs.env"

range="${HOGDOT_WEBGPU_FORK_POINT}..${HOGDOT_WEBGPU_REF}"
git -C "$here" rev-parse --verify --quiet "${HOGDOT_WEBGPU_REF}^{commit}" >/dev/null || exit 0

shas="$(printf '%s' "$command" |
	grep -oE 'Webgpu-Source:[^\\"'"'"']*' |
	sed 's/Webgpu-Source://' |
	tr -c '0-9a-f' '\n' |
	grep -xE '[0-9a-f]{7,40}' || true)"

if [ -z "$shas" ]; then
	printf 'BLOCKED — Webgpu-Port: is present but no valid Webgpu-Source: SHA was found.\n' >&2
	printf 'Add at least one short SHA from: git log --oneline %s -- <path>\n' "$range" >&2
	exit 2
fi

bad=()
while IFS= read -r sha; do
	[ -n "$sha" ] || continue
	full="$(git -C "$here" rev-parse --verify --quiet "${sha}^{commit}" 2>/dev/null)" || {
		bad+=("  $sha — does not resolve to any commit")
		continue
	}
	# in-range means: an ancestor of the fork tip, but NOT already an ancestor of the
	# fork point (which would make it an upstream commit, not a WebGPU one).
	if ! git -C "$here" merge-base --is-ancestor "$full" "$HOGDOT_WEBGPU_REF" 2>/dev/null ||
		git -C "$here" merge-base --is-ancestor "$full" "$HOGDOT_WEBGPU_FORK_POINT" 2>/dev/null; then
		bad+=("  $sha — resolves, but is not in $range")
	fi
done <<EOF
$shas
EOF

if [ "${#bad[@]}" -gt 0 ]; then
	printf 'BLOCKED — fabricated or out-of-range Webgpu-Source provenance:\n\n' >&2
	printf '%s\n' "${bad[@]}" >&2
	printf '\nEvery cited SHA must come from:\n    git log --oneline %s -- <path>\n' "$range" >&2
	printf 'A wrong SHA is worse than none — it looks like a valid audit trail forever after.\n' >&2
	exit 2
fi

exit 0
