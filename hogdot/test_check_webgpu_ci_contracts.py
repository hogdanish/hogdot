from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from hogdot.check_webgpu_ci_contracts import TRACKED_BENCHMARK_SCENES, WORKFLOW_PATHS, check_contracts


class WebGpuCiContractsTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        scene_selection = ",".join(TRACKED_BENCHMARK_SCENES)
        for workflow_path in WORKFLOW_PATHS:
            destination = self.root / workflow_path
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_text(
                "env:\n"
                "  EM_VERSION_WEBGPU: 6.0.8\n"
                "  EMCC_CFLAGS: -Wno-unused-template\n"
                "steps:\n"
                "  - uses: emscripten-core/setup-emsdk@0123456789abcdef\n"
                "  - version: ${{ env.EM_VERSION_WEBGPU }}\n"
                "  - run: scons import_env_vars=EMCC_CFLAGS use_closure_compiler=no\n"
                "  - run: git restore --source=HEAD --worktree -- editor\n"
                "  - run: sudo apt-get install -y mesa-vulkan-drivers vulkan-tools\n"
                "  - run: vulkaninfo --summary\n"
                "  - run: xvfb-run --auto-servernum node run_scenes.mjs --export "
                "--browser chrome "
                f"--scenes {scene_selection} "
                "--editor-bin ../../bin/godot.linuxbsd.editor.x86_64 "
                "--timeout 180000\n"
                "  - run: xvfb-run --auto-servernum node run_scenes.mjs "
                "--browser firefox "
                f"--scenes {scene_selection} "
                "--timeout 180000\n"
                "  - run: xvfb-run --auto-servernum node screenshot_tests.mjs\n"
                "  - run: install template bin/godot.web.template_debug.wasm32.nothreads.zip\n"
                "  - run: install template bin/godot.web.template_release.wasm32.nothreads.zip\n"
                "  - run: GODOT_DUMP_SPIRV=/tmp/spirv_dump timeout 120 \\\n"
                "      xvfb-run --auto-servernum bin/godot.linuxbsd.editor.x86_64 "
                "--rendering-method mobile --quit-after 10\n"
                "  - run: test -f webgpu_tests/test_project/export/index.html\n"
                "  - run: 'test \"${#spirv_files[@]}\" -gt 0'\n"
                "  - name: Upload SPIR-V dump\n"
                "    with:\n"
                "      name: spirv-dump\n"
                "      if-no-files-found: error\n"
                "  - name: Upload WebGPU export\n"
                "    with:\n"
                "      name: webgpu-export\n"
                "      if-no-files-found: error\n"
                "  - name: Upload screenshots\n"
                "    with:\n"
                "      name: screenshot-comparison\n"
                "      if-no-files-found: error\n"
                '  - run: if [ "${{ needs.screenshot-comparison.result }}" != "success" ]; then\n',
                encoding="utf-8",
            )

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def test_matching_webgpu_toolchains_pass(self) -> None:
        self.assertEqual(check_contracts(self.root), [])

    def test_upstream_emsdk_pin_in_webgpu_tests_fails(self) -> None:
        tests_workflow = self.root / ".github/workflows/webgpu_tests.yml"
        contents = tests_workflow.read_text(encoding="utf-8")
        contents = contents.replace("EM_VERSION_WEBGPU: 6.0.8", "EM_VERSION: 4.0.11")
        contents = contents.replace("env.EM_VERSION_WEBGPU", "env.EM_VERSION")
        tests_workflow.write_text(contents, encoding="utf-8")

        errors = check_contracts(self.root)

        self.assertTrue(any("expected exactly one EM_VERSION_WEBGPU" in error for error in errors))
        self.assertTrue(any("missing `version: ${{ env.EM_VERSION_WEBGPU }}`" in error for error in errors))

    def test_mismatched_webgpu_pin_fails(self) -> None:
        tests_workflow = self.root / ".github/workflows/webgpu_tests.yml"
        contents = tests_workflow.read_text(encoding="utf-8")
        tests_workflow.write_text(contents.replace("6.0.8", "6.0.9", 1), encoding="utf-8")

        errors = check_contracts(self.root)

        self.assertTrue(any("WebGPU emsdk pins must match" in error for error in errors))

    def test_required_artifacts_must_fail_when_files_are_missing(self) -> None:
        tests_workflow = self.root / ".github/workflows/webgpu_tests.yml"
        contents = tests_workflow.read_text(encoding="utf-8")
        for artifact_name in ("spirv-dump", "webgpu-export", "screenshot-comparison"):
            with self.subTest(artifact_name=artifact_name):
                marker = f"name: {artifact_name}\n      if-no-files-found: error"
                tests_workflow.write_text(
                    contents.replace(marker, f"name: {artifact_name}\n      if-no-files-found: warn"),
                    encoding="utf-8",
                )

                errors = check_contracts(self.root)

                self.assertTrue(
                    any(f"artifact `{artifact_name}` must set `if-no-files-found: error`" in error for error in errors)
                )

    def test_template_setup_must_not_hard_code_an_old_engine_version(self) -> None:
        tests_workflow = self.root / ".github/workflows/webgpu_tests.yml"
        contents = tests_workflow.read_text(encoding="utf-8")
        tests_workflow.write_text(
            contents + "  - run: mkdir -p ~/.local/share/godot/export_templates/4.6.2.dev\n",
            encoding="utf-8",
        )

        errors = check_contracts(self.root)

        self.assertTrue(any("must not hard-code the engine version directory" in error for error in errors))

    def test_test_project_export_must_not_ignore_failure(self) -> None:
        tests_workflow = self.root / ".github/workflows/webgpu_tests.yml"
        contents = tests_workflow.read_text(encoding="utf-8")
        tests_workflow.write_text(
            contents + '  - run: --export-release "WebGPU" export/index.html || true\n',
            encoding="utf-8",
        )

        errors = check_contracts(self.root)

        self.assertTrue(any("fail-open" in error and "export/index.html" in error for error in errors))

    def test_spirv_dump_requires_a_windowed_mobile_renderer(self) -> None:
        tests_workflow = self.root / ".github/workflows/webgpu_tests.yml"
        contents = tests_workflow.read_text(encoding="utf-8")
        tests_workflow.write_text(
            contents.replace(
                "xvfb-run --auto-servernum bin/godot.linuxbsd.editor.x86_64",
                "bin/godot.linuxbsd.editor.x86_64 --headless",
            ),
            encoding="utf-8",
        )

        errors = check_contracts(self.root)

        self.assertTrue(
            any("missing `xvfb-run --auto-servernum bin/godot.linuxbsd.editor.x86_64`" in error for error in errors)
        )

    def test_scene_smoketest_must_export_selected_scenes(self) -> None:
        tests_workflow = self.root / ".github/workflows/webgpu_tests.yml"
        contents = tests_workflow.read_text(encoding="utf-8")
        tests_workflow.write_text(contents.replace(" --export ", " "), encoding="utf-8")

        errors = check_contracts(self.root)

        self.assertTrue(any("missing `--export`" in error for error in errors))

    def test_editor_sources_must_be_restored_after_the_template_build(self) -> None:
        tests_workflow = self.root / ".github/workflows/webgpu_tests.yml"
        contents = tests_workflow.read_text(encoding="utf-8")
        tests_workflow.write_text(
            contents.replace("git restore --source=HEAD --worktree -- editor", "true"), encoding="utf-8"
        )

        errors = check_contracts(self.root)

        self.assertTrue(any("missing `git restore --source=HEAD --worktree -- editor`" in error for error in errors))

    def test_each_tracked_benchmark_is_required_in_both_browsers(self) -> None:
        tests_workflow = self.root / ".github/workflows/webgpu_tests.yml"
        contents = tests_workflow.read_text(encoding="utf-8")
        complete_selection = ",".join(TRACKED_BENCHMARK_SCENES)
        selection_parts = contents.split(complete_selection)
        self.assertEqual(len(selection_parts), 3)

        for browser_index, browser in enumerate(("chrome", "firefox")):
            for omitted_scene in TRACKED_BENCHMARK_SCENES:
                with self.subTest(browser=browser, omitted_scene=omitted_scene):
                    incomplete_selection = ",".join(
                        scene for scene in TRACKED_BENCHMARK_SCENES if scene != omitted_scene
                    )
                    selections = [complete_selection, complete_selection]
                    selections[browser_index] = incomplete_selection
                    tests_workflow.write_text(
                        selection_parts[0] + selections[0] + selection_parts[1] + selections[1] + selection_parts[2],
                        encoding="utf-8",
                    )

                    errors = check_contracts(self.root)

                    self.assertTrue(
                        any(
                            "hosted scene selection must contain every tracked benchmark exactly once" in error
                            and omitted_scene in error
                            for error in errors
                        )
                    )

    def test_both_hosted_browsers_are_required(self) -> None:
        tests_workflow = self.root / ".github/workflows/webgpu_tests.yml"
        contents = tests_workflow.read_text(encoding="utf-8")
        tests_workflow.write_text(contents.replace("--browser firefox", "--browser chrome"), encoding="utf-8")

        errors = check_contracts(self.root)

        self.assertTrue(any("`--browser chrome` scene invocation, found 2" in error for error in errors))
        self.assertTrue(any("`--browser firefox` scene invocation, found 0" in error for error in errors))

    def test_hosted_scene_deadlines_cannot_regress_to_the_known_short_timeout(self) -> None:
        tests_workflow = self.root / ".github/workflows/webgpu_tests.yml"
        contents = tests_workflow.read_text(encoding="utf-8")
        tests_workflow.write_text(contents.replace("--timeout 180000", "--timeout 30000", 1), encoding="utf-8")

        errors = check_contracts(self.root)

        self.assertTrue(any("bounded 180000 ms scene deadline" in error for error in errors))


if __name__ == "__main__":
    unittest.main()
