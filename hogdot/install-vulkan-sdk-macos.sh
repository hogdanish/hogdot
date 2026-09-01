#!/usr/bin/env bash
# Install a PINNED, digest-verified LunarG Vulkan SDK for macOS builds.
#
# ⚠ This deliberately REPLACES upstream's misc/scripts/install_vulkan_sdk_macos.sh
#   in the cg-release channel; it does not wrap it. That script fetches
#   https://sdk.lunarg.com/sdk/download/latest/mac/{config.json,vulkan-sdk.zip}
#   and executes the installer straight out of the archive with no version pin,
#   no digest and no signature check. In a job that also holds a repository
#   credential that is two defects at once:
#
#     * supply chain — ~360 MiB of code fetched over the wire and run, unverified,
#       on the runner that produces a shipped release asset. Whatever LunarG's CDN
#       serves that minute is what executes.
#     * reproducibility — "latest" means two runs a fortnight apart build the same
#       commit against different SDKs, with nothing anywhere recording which one.
#
#   Upstream's script is left untouched on purpose: it is mainline Godot's file and
#   editing it would conflict on every rebase-forward. This one lives under hogdot/,
#   the fork-local directory mainline will never create, so it survives them all.
#
# ⚠ BUMPING THE PIN moves TWO constants and they must move together. A version
#   without its matching digest is worse than no pin at all — it looks verified.
#
#     curl -fsSL "https://sdk.lunarg.com/sdk/download/<version>/mac/vulkan-sdk.zip" \
#       -o /tmp/vulkan-sdk.zip && shasum -a 256 /tmp/vulkan-sdk.zip
#
#   The current version of record is whatever `latest/mac/config.json` reports
#   (`.version`); LunarG serves every past version at the same URL shape, so the
#   pin never rots out from under the channel the way `latest` does.
#
# Decision record: .claude/skills/build-export/SKILL.md ("The cg-release channel").
set -euo pipefail

# LunarG macOS SDK 1.4.357.1, released 2026-08-17. sha256 of the 376,108,497-byte
# vulkan-sdk.zip, measured 2026-08-28 by downloading it (content-length and a full
# CRC pass both agree). This was `latest` at the time, so pinning it changed
# nothing about what the channel builds — only about what it is willing to run.
readonly SDK_VERSION='1.4.357.1'
readonly SDK_SHA256='cf23e604e6b8b82c18eaba329f5623ea5a309d949a98d49a61a161d576c769a5'
readonly SDK_URL="https://sdk.lunarg.com/sdk/download/${SDK_VERSION}/mac/vulkan-sdk.zip"

# Where LunarG's installer lands by default, and where SCons looks: platform_methods
# get_mvk_sdk_path() scans ~/VulkanSDK/* and takes the highest version that carries a
# MoltenVK.xcframework. Installing beside an existing newer SDK would therefore be
# silently ignored — which is exactly why this must be a pin and not a floor.
readonly SDK_ROOT="$HOME/VulkanSDK/$SDK_VERSION"

# Hand the pin to the caller's build manifest when running under Actions, so the
# release ledger cannot drift from what was actually installed. This script is the
# single source of truth for the version; nothing else may restate it.
if [ -n "${GITHUB_ENV:-}" ]; then
	printf 'VULKAN_SDK_VERSION=%s\n' "$SDK_VERSION" >>"$GITHUB_ENV"
fi

if [ -d "$SDK_ROOT" ]; then
	echo "Vulkan SDK $SDK_VERSION already present at $SDK_ROOT — skipping install."
	exit 0
fi

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
archive="$workdir/vulkan-sdk.zip"

echo "Downloading LunarG Vulkan SDK $SDK_VERSION…"
# --fail so an HTML error page never reaches the verifier; --retry for CDN flakiness.
curl --fail --location --silent --show-error --retry 3 --retry-delay 5 \
	--output "$archive" "$SDK_URL"

# ⚠ Verify BEFORE the archive is opened, let alone executed. `shasum --check`
#   exits non-zero on a mismatch and `set -e` turns that into a failed job, so the
#   failure mode is closed by construction: there is no path from a bad download to
#   a running installer. Keep this step above the unzip, always.
echo "Verifying sha256…"
if ! printf '%s  %s\n' "$SDK_SHA256" "$archive" | shasum -a 256 --check --status; then
	{
		echo "::error::Vulkan SDK digest mismatch — refusing to unpack or run the installer."
		echo "  url      $SDK_URL"
		echo "  expected $SDK_SHA256"
		echo "  actual   $(shasum -a 256 "$archive" | cut -d ' ' -f 1)"
		echo "  Either LunarG re-cut this version, or the download was tampered with."
		echo "  Do NOT 'fix' this by updating the digest without establishing which."
	} >&2
	exit 1
fi
echo "Digest OK ($SDK_SHA256)."

unzip -q "$archive" -d "$workdir"

installer="$workdir/vulkansdk-macOS-$SDK_VERSION.app/Contents/MacOS/vulkansdk-macOS-$SDK_VERSION"
if [ ! -x "$installer" ]; then
	echo "::error::Verified archive does not contain the expected installer at $installer." >&2
	echo "LunarG changed the archive layout; update this script rather than the digest." >&2
	exit 1
fi

# Same invocation as upstream's script — unattended, licenses accepted, default
# target (~/VulkanSDK/$SDK_VERSION). Only the provenance of the bytes has changed.
"$installer" --accept-licenses --default-answer --confirm-command install

echo "Vulkan SDK $SDK_VERSION installed to $SDK_ROOT."
