"""Fail closed when WebGPU CI consumers drift from the shipped emsdk pin."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

WORKFLOW_PATHS = (
    Path(".github/workflows/web_builds.yml"),
    Path(".github/workflows/cg_release.yml"),
    Path(".github/workflows/webgpu_tests.yml"),
)
PIN_PATTERN = re.compile(r"^\s*EM_VERSION_WEBGPU:\s*['\"]?([^\s'\"]+)['\"]?\s*$", re.MULTILINE)
SCENE_SELECTION_PATTERN = re.compile(r"--scenes\s+([a-z0-9_,.-]+)")
TRACKED_BENCHMARK_SCENES = (
    "benchmark_sprites",
    "benchmark_pbr",
    "benchmark_instances",
    "benchmark_particles",
    "benchmark_animated",
    "benchmark_postfx",
    "benchmark_shadows",
    "benchmark_batching",
)
REQUIRED_ARTIFACTS = ("spirv-dump", "webgpu-export", "screenshot-comparison")


def _read_pin(root: Path, relative_path: Path) -> tuple[str | None, list[str]]:
    path = root / relative_path
    if not path.is_file():
        return None, [f"missing workflow: {relative_path}"]

    matches = PIN_PATTERN.findall(path.read_text(encoding="utf-8"))
    if len(matches) != 1:
        return None, [f"{relative_path}: expected exactly one EM_VERSION_WEBGPU pin, found {len(matches)}"]
    return matches[0], []


def check_contracts(root: Path) -> list[str]:
    """Return every contract violation under *root*."""
    errors: list[str] = []
    pins: dict[Path, str] = {}

    for relative_path in WORKFLOW_PATHS:
        pin, path_errors = _read_pin(root, relative_path)
        errors.extend(path_errors)
        if pin is not None:
            pins[relative_path] = pin

    if pins:
        pin_values = set(pins.values())
        if len(pin_values) != 1:
            rendered = ", ".join(f"{path}={pin}" for path, pin in pins.items())
            errors.append(f"WebGPU emsdk pins must match: {rendered}")

    tests_path = root / ".github/workflows/webgpu_tests.yml"
    if tests_path.is_file():
        tests_workflow = tests_path.read_text(encoding="utf-8")
        required_fragments = (
            "uses: emscripten-core/setup-emsdk@",
            "version: ${{ env.EM_VERSION_WEBGPU }}",
            "EMCC_CFLAGS: -Wno-unused-template",
            "import_env_vars=EMCC_CFLAGS",
            "use_closure_compiler=no",
            "git restore --source=HEAD --worktree -- editor",
            "sudo apt-get install -y mesa-vulkan-drivers vulkan-tools",
            "vulkaninfo --summary",
            "xvfb-run --auto-servernum node run_scenes.mjs",
            "--export",
            "--editor-bin ../../bin/godot.linuxbsd.editor.x86_64",
            "--timeout 180000",
            "xvfb-run --auto-servernum node screenshot_tests.mjs",
            "bin/godot.web.template_debug.wasm32.nothreads.zip",
            "bin/godot.web.template_release.wasm32.nothreads.zip",
            "GODOT_DUMP_SPIRV=/tmp/spirv_dump timeout 120",
            "xvfb-run --auto-servernum bin/godot.linuxbsd.editor.x86_64",
            "--rendering-method mobile --quit-after 10",
            "test -f webgpu_tests/test_project/export/index.html",
            'test "${#spirv_files[@]}" -gt 0',
            'if [ "${{ needs.screenshot-comparison.result }}" != "success" ]; then',
        )
        for fragment in required_fragments:
            if fragment not in tests_workflow:
                errors.append(f".github/workflows/webgpu_tests.yml: missing `{fragment}`")

        if re.search(r"export_templates/\d+\.\d+\.\d+\.(?:dev|stable)", tests_workflow):
            errors.append(
                ".github/workflows/webgpu_tests.yml: template setup must not hard-code the engine version directory"
            )

        fail_open_fragments = (
            "web_nothreads_release.zip || true",
            '--export-release "WebGPU" export/index.html || true',
        )
        for fragment in fail_open_fragments:
            if fragment in tests_workflow:
                errors.append(f".github/workflows/webgpu_tests.yml: fail-open `{fragment}` is forbidden")

        for artifact_name in REQUIRED_ARTIFACTS:
            marker = f"name: {artifact_name}"
            block_start = tests_workflow.find(marker)
            if block_start < 0:
                errors.append(f".github/workflows/webgpu_tests.yml: missing artifact `{artifact_name}`")
                continue
            remainder = tests_workflow[block_start + len(marker) :]
            next_step = re.search(r"\n\s*-\s+name:", remainder)
            block_end = block_start + len(marker) + next_step.start() if next_step is not None else len(tests_workflow)
            artifact_block = tests_workflow[block_start:block_end]
            if "if-no-files-found: error" not in artifact_block:
                errors.append(
                    ".github/workflows/webgpu_tests.yml: artifact "
                    f"`{artifact_name}` must set `if-no-files-found: error`"
                )

        for browser in ("chrome", "firefox"):
            browser_flag = f"--browser {browser}"
            browser_count = tests_workflow.count(browser_flag)
            if browser_count != 1:
                errors.append(
                    ".github/workflows/webgpu_tests.yml: expected exactly one hosted "
                    f"`{browser_flag}` scene invocation, found {browser_count}"
                )

        timeout_count = tests_workflow.count("--timeout 180000")
        if timeout_count != 2:
            errors.append(
                ".github/workflows/webgpu_tests.yml: expected the bounded 180000 ms scene "
                f"deadline in both hosted browser invocations, found {timeout_count}"
            )

        scene_selections = SCENE_SELECTION_PATTERN.findall(tests_workflow)
        if len(scene_selections) != 2:
            errors.append(
                ".github/workflows/webgpu_tests.yml: expected exactly two hosted scene selections "
                f"(Chromium + Firefox), found {len(scene_selections)}"
            )
        expected_scenes = set(TRACKED_BENCHMARK_SCENES)
        for selection in scene_selections:
            selected_scenes = selection.split(",")
            if len(selected_scenes) != len(TRACKED_BENCHMARK_SCENES) or set(selected_scenes) != expected_scenes:
                missing = sorted(expected_scenes - set(selected_scenes))
                unexpected = sorted(set(selected_scenes) - expected_scenes)
                errors.append(
                    ".github/workflows/webgpu_tests.yml: hosted scene selection must contain every "
                    f"tracked benchmark exactly once (missing={missing}, unexpected={unexpected})"
                )

    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()

    errors = check_contracts(args.root.resolve())
    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1

    pin, _ = _read_pin(args.root.resolve(), WORKFLOW_PATHS[0])
    print(f"WebGPU CI contracts verified (emsdk {pin}).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
