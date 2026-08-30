#!/usr/bin/env bash
# Build tint_convert_cli — native host tool for build-time SPIR-V → WGSL conversion.
#
# Usage:
#   ./drivers/webgpu/tint_cli/build.sh          # Build with auto-detected parallelism
#   ./drivers/webgpu/tint_cli/build.sh --clean   # Remove build artifacts and rebuild
#   ./drivers/webgpu/tint_cli/build.sh --wasm    # Build tint_convert.wasm for the Tint worker
#
# Output: bin/tint_convert_cli, or bin/tint_convert.{js,wasm} with --wasm.
#
# ⚠ --wasm builds a SECOND copy of Tint and SPIRV-Tools, as a standalone module
# the Tint Web Worker loads. It has to be a second copy: a Worker is its own JS
# realm with its own wasm instance and cannot reach the Tint already linked into
# the engine module. That download is the entire cost of the worker approach, so
# this script prints the byte sizes at the end — they are the ship-decision
# input, not a footnote.
#
# ⚠ The two modes share every source list and every Tint define on purpose. The
# worker's WGSL must be byte-identical to the main thread's, and a source list
# that could drift is the cheapest possible way to lose that.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
cd "$REPO_ROOT"

# Directories.
TINT_DIR="thirdparty/tint"
SPIRV_TOOLS_DIR="thirdparty/spirv-tools"
SPIRV_HEADERS_DIR="thirdparty/spirv-headers"
SHIM_DIR="drivers/webgpu/tint_cli"

JOBS="${JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)}"
CXX="${CXX:-c++}"

# Parse the target mode before anything derives paths from it.
WASM=false
for arg in "$@"; do
    [[ "$arg" == "--wasm" ]] && WASM=true
done

if [[ "$WASM" == true ]]; then
    # ⚠ Separate object tree. Native and wasm objects have the same names and
    # would silently link into each other's binary through the mtime skip.
    BUILD_DIR="drivers/webgpu/tint_cli/.build-wasm"
    CXX="${EMXX:-em++}"
    # ⚠ num_jobs is capped for the same reason webgpu=yes web builds are: nine
    # concurrent em++ processes on the Tint translation units exhaust this
    # machine's 24 GB, and the tell is a pegged machine with quiet fans.
    JOBS="${JOBS_WASM:-4}"
else
    BUILD_DIR="drivers/webgpu/tint_cli/.build"
fi

# Wait until fewer than $JOBS background compiles are running.
# `wait -n` needs bash >= 4.3; macOS ships bash 3.2, where it fails instantly and
# leaves the caller with no throttle at all (i.e. ~1200 concurrent compilers).
# This poll works on every bash.
throttle() {
    while (( $(jobs -r | wc -l) >= JOBS )); do
        sleep 0.05
    done
}

# Parse args.
CLEAN=false
for arg in "$@"; do
    [[ "$arg" == "--clean" ]] && CLEAN=true
done

if [[ "$CLEAN" == true ]]; then
    echo "Cleaning build artifacts..."
    rm -rf "$BUILD_DIR"
fi

mkdir -p "$BUILD_DIR/spirv_tools" "$BUILD_DIR/tint" "$BUILD_DIR/cli"

# Translation-pipeline stamp: hash of the files named in pipeline_id_inputs.txt,
# embedded into the binary and printed by --pipeline-id. The editor's shader
# baker compares it against its own build-time copy of the same hash.
PIPELINE_ID="$(
    grep -v '^#' "$SHIM_DIR/pipeline_id_inputs.txt" | while IFS= read -r f; do
        [[ -n "$f" ]] && cat "$f"
    done | shasum -a 256 | cut -c1-16
)"
echo "Pipeline id: $PIPELINE_ID"

# Common flags.
WARNINGS="-w"  # Suppress warnings from thirdparty code.
COMMON_FLAGS="-O2 $WARNINGS"

if [[ "$WASM" == true ]]; then
    # ⚠ Must match platform/web/detect.py's longjmp mode exactly, on BOTH compile
    # and link. Tint's vendored ICE handler (patch 0008) longjmps back out of an
    # internal error, and Emscripten's two longjmp implementations are not ABI
    # compatible: built with the default, the module links clean and then dies at
    # the first translation with `RuntimeError: function signature mismatch` in an
    # `invoke_viii` frame — a runtime failure with no build-time signal.
    #
    # ⚠ -fno-exceptions comes with it, and the two are ONE decision. Without it
    # libc++ emits __cxa_throw, Emscripten does not link throwing support under
    # wasm sjlj, and the link fails with "DISABLE_EXCEPTION_THROWING was set ...
    # but such support is required by symbol '__cxa_throw'" — and the obvious
    # escape, -sDISABLE_EXCEPTION_THROWING=0, is refused outright:
    # "SUPPORT_LONGJMP=wasm cannot be used with DISABLE_EXCEPTION_THROWING=0".
    # This is exactly how the engine already compiles Tint (SConstruct's
    # disable_exceptions defaults to True), so the two copies match rather than
    # merely both working. Tint's ICE path does not need throwing: patch 0008's
    # handler longjmps, which is the reason for the sjlj mode above.
    COMMON_FLAGS="$COMMON_FLAGS -sSUPPORT_LONGJMP=wasm -fno-exceptions"
fi

# Include paths for SPIRV-Tools.
SPIRV_TOOLS_INCLUDES=(
    -I"$SPIRV_TOOLS_DIR"
    -I"$SPIRV_TOOLS_DIR/source/"
    -I"$SPIRV_TOOLS_DIR/include/"
    -I"$SPIRV_TOOLS_DIR/generated/"
    -I"$SPIRV_HEADERS_DIR/include/"
    -I"$SPIRV_HEADERS_DIR/include/spirv/unified1/"
)

# Include paths for Tint.
TINT_INCLUDES=(
    -I"$TINT_DIR"
    -I"$TINT_DIR/src/"
    -I"$SPIRV_TOOLS_DIR"
    -I"$SPIRV_TOOLS_DIR/source/"
    -I"$SPIRV_TOOLS_DIR/include/"
    -I"$SPIRV_TOOLS_DIR/generated/"
    -I"$SPIRV_HEADERS_DIR/include/"
    -I"$SPIRV_HEADERS_DIR/include/spirv/unified1/"
)

# Tint preprocessor defines (must match SCsub).
TINT_DEFINES=(
    -DTINT_BUILD_SPV_READER=1
    -DTINT_BUILD_WGSL_WRITER=1
    -DTINT_BUILD_WGSL_READER=0
    -DTINT_BUILD_SPV_WRITER=0
    -DTINT_BUILD_GLSL_WRITER=0
    -DTINT_BUILD_HLSL_WRITER=0
    -DTINT_BUILD_MSL_WRITER=0
    -DTINT_BUILD_NULL_WRITER=0
    -DTINT_BUILD_SYNTAX_TREE_WRITER=0
    -DTINT_BUILD_IR_BINARY=0
)

# Detect platform-specific Tint sources.
# ⚠ wasm takes the `_other` set rather than the host's: Tint's posix variants
# reach for fork/exec and real temp files, which Emscripten either stubs or
# fails to link, and none of it is on the translation path anyway.
if [[ "$WASM" == true ]]; then
    TINT_PLATFORM_SOURCES=(
        "src/tint/utils/command/command_other.cc"
        "src/tint/utils/file/tmpfile_other.cc"
        "src/tint/utils/system/env_other.cc"
        "src/tint/utils/system/terminal_other.cc"
        "src/tint/utils/text/styled_text_printer_other.cc"
    )
else
case "$(uname -s)" in
    Darwin)
        TINT_PLATFORM_SOURCES=(
            "src/tint/utils/command/command_posix.cc"
            "src/tint/utils/file/tmpfile_posix.cc"
            "src/tint/utils/system/env_other.cc"
            "src/tint/utils/system/executable_file_mac.cc"
            "src/tint/utils/system/terminal_posix.cc"
            "src/tint/utils/text/styled_text_printer_posix.cc"
        )
        ;;
    Linux)
        TINT_PLATFORM_SOURCES=(
            "src/tint/utils/command/command_posix.cc"
            "src/tint/utils/file/tmpfile_posix.cc"
            "src/tint/utils/system/env_other.cc"
            "src/tint/utils/system/executable_path_linux.cc"
            "src/tint/utils/system/terminal_posix.cc"
            "src/tint/utils/text/styled_text_printer_posix.cc"
        )
        ;;
    *)
        TINT_PLATFORM_SOURCES=(
            "src/tint/utils/command/command_other.cc"
            "src/tint/utils/file/tmpfile_other.cc"
            "src/tint/utils/system/env_other.cc"
            "src/tint/utils/system/terminal_other.cc"
            "src/tint/utils/text/styled_text_printer_other.cc"
        )
        ;;
esac
fi

# ─────────────────────────────────────────────────────────────────────────────
# Compile function: skip if .o is newer than source.
# ─────────────────────────────────────────────────────────────────────────────
compile_one() {
    local src="$1"
    local obj="$2"
    local std="$3"
    shift 3
    local flags=("$@")

    if [[ -f "$obj" && "$obj" -nt "$src" ]]; then
        return 0
    fi

    mkdir -p "$(dirname "$obj")"
    $CXX -c "$src" -o "$obj" -std="$std" $COMMON_FLAGS "${flags[@]}"
}

# ─────────────────────────────────────────────────────────────────────────────
# 1. Compile SPIRV-Tools
# ─────────────────────────────────────────────────────────────────────────────
echo "[1/4] Compiling SPIRV-Tools..."

SPIRV_TOOLS_OBJS=()
# Collect all .cpp files from the SCsub list (everything under source/).
while IFS= read -r src; do
    objname="${src#$SPIRV_TOOLS_DIR/}"
    objname="${objname%.cpp}.o"
    obj="$BUILD_DIR/spirv_tools/$objname"
    SPIRV_TOOLS_OBJS+=("$obj")
    # Run in parallel via background jobs, bounded by $JOBS.
    throttle
    compile_one "$src" "$obj" "c++17" "${SPIRV_TOOLS_INCLUDES[@]}" &
done < <(find "$SPIRV_TOOLS_DIR/source" -name '*.cpp' -not -name '*test*' -not -name '*_test.cpp' -not -path '*/test/*' | sort)
wait

echo "  ${#SPIRV_TOOLS_OBJS[@]} objects"

# ─────────────────────────────────────────────────────────────────────────────
# 2. Compile Tint
# ─────────────────────────────────────────────────────────────────────────────
echo "[2/4] Compiling Tint..."

# Collect Tint source files from the SCsub list.
# Rather than duplicating the full 400-line list, find all .cc files that match
# the SCsub pattern (excluding test files, benchmarks, fuzzers).
TINT_OBJS=()
while IFS= read -r src; do
    objname="${src#$TINT_DIR/}"
    objname="${objname%.cc}.o"
    obj="$BUILD_DIR/tint/$objname"
    TINT_OBJS+=("$obj")
    throttle
    compile_one "$src" "$obj" "c++20" "${TINT_INCLUDES[@]}" "${TINT_DEFINES[@]}" &
done < <(find "$TINT_DIR/src/tint" -name '*.cc' \
    -not -name '*_test.cc' \
    -not -name '*_bench*.cc' \
    -not -name '*_fuzz*.cc' \
    -not -path '*/test/*' \
    -not -path '*/bench/*' \
    -not -path '*/fuzz/*' \
    -not -path '*/cmd/*' \
    -not -name 'main.cc' \
    -not -name 'decode.cc' \
    -not -name 'encode.cc' \
    -not -name 'command_posix.cc' \
    -not -name 'command_windows.cc' \
    -not -name 'command_other.cc' \
    -not -name 'tmpfile_posix.cc' \
    -not -name 'tmpfile_windows.cc' \
    -not -name 'tmpfile_other.cc' \
    -not -name 'env_other.cc' \
    -not -name 'env_windows.cc' \
    -not -name 'executable_file_mac.cc' \
    -not -name 'executable_path_linux.cc' \
    -not -name 'executable_path_windows.cc' \
    -not -name 'terminal_posix.cc' \
    -not -name 'terminal_windows.cc' \
    -not -name 'terminal_other.cc' \
    -not -name 'styled_text_printer_posix.cc' \
    -not -name 'styled_text_printer_windows.cc' \
    -not -name 'styled_text_printer_other.cc' \
    -not -name 'args.cc' \
    -not -name 'cli.cc' \
    | sort)

# Add platform-specific sources.
for src in "${TINT_PLATFORM_SOURCES[@]}"; do
    full_src="$TINT_DIR/$src"
    if [[ -f "$full_src" ]]; then
        objname="${src%.cc}.o"
        obj="$BUILD_DIR/tint/$objname"
        TINT_OBJS+=("$obj")
        compile_one "$full_src" "$obj" "c++20" "${TINT_INCLUDES[@]}" "${TINT_DEFINES[@]}" &
    fi
done

# CLI/args utility needed by Tint internals.
for src in "src/tint/utils/command/args.cc" "src/tint/utils/command/cli.cc"; do
    full_src="$TINT_DIR/$src"
    if [[ -f "$full_src" ]]; then
        objname="${src%.cc}.o"
        obj="$BUILD_DIR/tint/$objname"
        TINT_OBJS+=("$obj")
        compile_one "$full_src" "$obj" "c++20" "${TINT_INCLUDES[@]}" "${TINT_DEFINES[@]}" &
    fi
done

wait
echo "  ${#TINT_OBJS[@]} objects"

# ─────────────────────────────────────────────────────────────────────────────
# 3. Compile CLI sources (spirv_preprocess.cpp + tint_wrapper.cpp + main.cpp)
# ─────────────────────────────────────────────────────────────────────────────
echo "[3/4] Compiling CLI sources..."

# spirv_preprocess.cpp — compiled with shim include path (before repo root so
# the shim core/templates/ is found instead of Godot's).
compile_one "drivers/webgpu/spirv_preprocess.cpp" \
    "$BUILD_DIR/cli/spirv_preprocess.o" \
    "c++17" \
    -I"$SHIM_DIR" \
    "${SPIRV_TOOLS_INCLUDES[@]}" &

# tint_wrapper.cpp — compiled with Tint C++20 environment.
compile_one "drivers/webgpu/tint_wrapper.cpp" \
    "$BUILD_DIR/cli/tint_wrapper.o" \
    "c++20" \
    "${TINT_INCLUDES[@]}" "${TINT_DEFINES[@]}" \
    -I"drivers/webgpu/" &

# The entry TU — main.cpp natively, wasm_entry.cpp for the worker module.
# Always recompiled: the pipeline-id stamp changes with files compile_one's
# mtime check cannot see.
if [[ "$WASM" == true ]]; then
    ENTRY_SRC="drivers/webgpu/tint_cli/wasm_entry.cpp"
else
    ENTRY_SRC="drivers/webgpu/tint_cli/main.cpp"
fi
$CXX -c "$ENTRY_SRC" \
    -o "$BUILD_DIR/cli/main.o" \
    -std=c++20 $COMMON_FLAGS \
    -I"$SHIM_DIR" \
    -I"drivers/webgpu/" \
    -I. \
    "${TINT_INCLUDES[@]}" "${TINT_DEFINES[@]}" \
    -DTINT_CLI_PIPELINE_ID="\"$PIPELINE_ID\"" &

wait

# ─────────────────────────────────────────────────────────────────────────────
# 4. Link
# ─────────────────────────────────────────────────────────────────────────────
echo "[4/4] Linking tint_convert_cli..."

# Filter to only .o files that were successfully compiled.
LINK_OBJS=("$BUILD_DIR/cli/main.o" "$BUILD_DIR/cli/spirv_preprocess.o" "$BUILD_DIR/cli/tint_wrapper.o")
for obj in "${SPIRV_TOOLS_OBJS[@]}" "${TINT_OBJS[@]}"; do
    [[ -f "$obj" ]] && LINK_OBJS+=("$obj")
done

echo "  Linking ${#LINK_OBJS[@]} objects..."

mkdir -p bin
if [[ "$WASM" == true ]]; then
    # ⚠ ENVIRONMENT=worker keeps the glue from emitting the DOM/node branches.
    # Override with TINT_WASM_ENVIRONMENT=worker,node to get a module `node` can
    # load, which is how the translation is verified against the shader corpus
    # without a browser; ship the default.
    # ENVIRONMENT=worker keeps the glue from emitting the DOM/node branches;
    # MODULARIZE gives the worker a factory it can await instead of a global
    # side effect. ALLOW_MEMORY_GROWTH because a large shader's SPIR-V plus the
    # Tint IR plus the WGSL text all live at once and the ceiling is a shader
    # nobody has written yet.
    # ⚠ No EXIT_RUNTIME and no main(): this module is a library of translate
    # calls, and a runtime that exits would take the second and later ones with
    # it.
    $CXX -o bin/tint_convert.js "${LINK_OBJS[@]}" -O2 \
        -sSUPPORT_LONGJMP=wasm \
        -sMODULARIZE=1 \
        -sEXPORT_NAME=TintConvert \
        -sENVIRONMENT="${TINT_WASM_ENVIRONMENT:-worker}" \
        -sALLOW_MEMORY_GROWTH=1 \
        -sEXPORTED_FUNCTIONS='["_tint_wasm_alloc","_tint_wasm_free","_tint_wasm_translate","_tint_wasm_result","_tint_wasm_error","_tint_wasm_pipeline_id","_malloc","_free"]' \
        -sEXPORTED_RUNTIME_METHODS='["ccall","cwrap","UTF8ToString","HEAPU8"]'
    echo
    echo "Built: bin/tint_convert.js + bin/tint_convert.wasm"
    echo "  pipeline id: $PIPELINE_ID"
    # The ship-decision number. Printed gzipped too, because that is what a
    # browser actually downloads over a Caddy/Cloudflare-served origin.
    for f in bin/tint_convert.js bin/tint_convert.wasm; do
        raw=$(wc -c < "$f" | tr -d ' ')
        gz=$(gzip -9 -c "$f" | wc -c | tr -d ' ')
        printf '  %-26s %10s B raw  %10s B gzip\n' "$(basename "$f")" "$raw" "$gz"
    done
else
    $CXX -o bin/tint_convert_cli "${LINK_OBJS[@]}" -O2
fi

if [[ "$WASM" != true ]]; then
    echo ""
    echo "Built: bin/tint_convert_cli ($(du -h bin/tint_convert_cli | cut -f1))"
fi
