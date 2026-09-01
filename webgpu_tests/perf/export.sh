#!/usr/bin/env bash
# Export the perf bed with a given editor and web template.
#
#   webgpu_tests/perf/export.sh --editor bin/godot.macos.editor.arm64 \
#       --template bin/godot.web.template_release.wasm32.nothreads.zip \
#       --out webgpu_tests/perf/exports/hogdot-main
#
# Options:
#   --editor BIN      editor binary (default bin/godot.macos.editor.arm64)
#   --template ZIP    web template zip; patched into export_presets.cfg for the run
#   --out DIR         output directory (index.html lands here)
#   --threads         use the "WebGPU Threads" preset (template must be a threads=yes build)
#   --debug           export-debug instead of export-release
#
# The pck is template-independent: the same exported index.pck runs against any template of the
# same engine major, so a build comparison can also be done by swapping index.{js,wasm} in place.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
PROJ="$HERE/project"
EDITOR_BIN="$ROOT/bin/godot.macos.editor.arm64"
TEMPLATE=""
OUT=""
PRESET="WebGPU"
MODE="--export-release"

while [ $# -gt 0 ]; do
	case "$1" in
		--editor) EDITOR_BIN="$2"; shift 2 ;;
		--template) TEMPLATE="$2"; shift 2 ;;
		--out) OUT="$2"; shift 2 ;;
		--threads) PRESET="WebGPU Threads"; shift ;;
		--debug) MODE="--export-debug"; shift ;;
		*) echo "unknown arg: $1" >&2; exit 2 ;;
	esac
done

[ -n "$TEMPLATE" ] || { echo "--template is required" >&2; exit 2; }
[ -n "$OUT" ] || { echo "--out is required" >&2; exit 2; }
[ -x "$EDITOR_BIN" ] || { echo "editor not executable: $EDITOR_BIN" >&2; exit 1; }
TEMPLATE="$(cd "$(dirname "$TEMPLATE")" && pwd)/$(basename "$TEMPLATE")"
[ -f "$TEMPLATE" ] || { echo "template not found: $TEMPLATE" >&2; exit 1; }
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

PRESETS="$PROJ/export_presets.cfg"
cp "$PRESETS" "$PRESETS.bak"
trap 'mv "$PRESETS.bak" "$PRESETS"' EXIT
# Point both debug and release at the requested template so either mode uses it.
sed -i '' "s|custom_template/debug=\"[^\"]*\"|custom_template/debug=\"$TEMPLATE\"|g; s|custom_template/release=\"[^\"]*\"|custom_template/release=\"$TEMPLATE\"|g" "$PRESETS"
# Inject head_include.js (page-side instruments) as one line: strip the leading block comment,
# join lines with spaces, escape double quotes. The file uses single quotes only by contract.
HEAD_JS="$(python3 - "$HERE/head_include.js" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
src = re.sub(r'/\*.*?\*/', '', src, flags=re.S)
one = ' '.join(l.strip() for l in src.splitlines() if l.strip())
print('<script>' + one.replace('"', '\\"') + '</script>')
PY
)"
python3 - "$PRESETS" "$HEAD_JS" <<'PY'
import re, sys
path, js = sys.argv[1], sys.argv[2]
s = open(path).read()
s = re.sub(r'html/head_include="[^\n]*"', lambda m: 'html/head_include="' + js + '"', s)
open(path, 'w').write(s)
PY

echo "editor:   $EDITOR_BIN"
echo "template: $TEMPLATE"
echo "preset:   $PRESET ($MODE)"
echo "out:      $OUT"

"$EDITOR_BIN" --headless --path "$PROJ" --import >/dev/null 2>&1 || true
# ⚠ NOT --headless: the shader baker needs a live RenderingDevice ("A --headless export can never
# bake shaders"), and a headless export silently ships an unbaked pck (0 baked hits, seconds of
# Tint at boot). The editor window flashes; that is the price of a baked pck.
"$EDITOR_BIN" --path "$PROJ" $MODE "$PRESET" "$OUT/index.html" 2>&1 | grep -v "^$" | grep -iE "baker|error|warn|DONE" | tail -20

[ -f "$OUT/index.html" ] && [ -f "$OUT/index.pck" ] || { echo "export failed: no index.html/index.pck in $OUT" >&2; exit 1; }
# Provenance: which engine hash the wasm carries, and the template it came from.
{
	echo "template=$TEMPLATE"
	echo "editor=$("$EDITOR_BIN" --version 2>/dev/null | tail -1)"
	echo "wasm_sha1=$(shasum "$OUT/index.wasm" | cut -d' ' -f1)"
	echo "exported=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$OUT/PROVENANCE.txt"
cat "$OUT/PROVENANCE.txt"
