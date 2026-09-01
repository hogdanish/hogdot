import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import {
    assertCompleteSceneResults,
    canvasScreenshotIsDataBearing,
    compositorCaptureTimeout,
    findMissingAutoloadTargets,
    sceneRunPassed,
} from './run_scenes.mjs';

const scenes = ['benchmark_sprites', 'benchmark_pbr'];
const browsers = ['chrome', 'firefox'];
const testDirectory = dirname(fileURLToPath(import.meta.url));

function completeResults() {
    return browsers.flatMap(browser => scenes.map(scene => ({ browser, scene, status: 'PASS' })));
}

test('scene result contract accepts a complete all-pass matrix', () => {
    assert.doesNotThrow(() => assertCompleteSceneResults(completeResults(), scenes, browsers));
});

test('scene result contract rejects the former all-skipped false green', () => {
    const results = browsers.flatMap(browser => scenes.map(scene => ({
        browser,
        scene,
        status: 'SKIP',
        reason: 'not exported',
    })));

    assert.throws(
        () => assertCompleteSceneResults(results, scenes, browsers),
        /Incomplete scene smoketest:.*chrome\/benchmark_sprites: SKIP \(not exported\)/,
    );
});

test('scene result contract rejects a missing browser result', () => {
    const results = completeResults();
    results.pop();

    assert.throws(
        () => assertCompleteSceneResults(results, scenes, browsers),
        /expected 4 results, found 3; firefox\/benchmark_pbr: expected one result, found 0/,
    );
});

test('a scene cannot pass when the engine never starts', () => {
    assert.equal(sceneRunPassed({
        engineStarted: false,
        totalErrors: 0,
        maxErrors: 0,
        deviceLost: false,
        blankCanvas: false,
        unmatchedPatterns: [],
    }), false);
});

test('a scene needs a data-bearing compositor screenshot', () => {
    assert.equal(canvasScreenshotIsDataBearing(2499), false);
    assert.equal(canvasScreenshotIsDataBearing(2500), true);
});

test('a compositor capture cannot outlive the per-scene deadline', () => {
    assert.equal(compositorCaptureTimeout(180000, 179500), 500);
    assert.equal(compositorCaptureTimeout(180000, 180000), 0);
    assert.equal(compositorCaptureTimeout(180000, 180500), 0);
});

test('a dangling project autoload fails the export preflight', () => {
    const projectPath = mkdtempSync(join(tmpdir(), 'hogdot-scene-project-'));
    const projectContents = '[autoload]\nBenchmarkProfiler="*res://benchmark_profiler.gd"\n';

    try {
        assert.deepEqual(
            findMissingAutoloadTargets(projectPath, projectContents),
            [join(projectPath, 'benchmark_profiler.gd')],
        );

        writeFileSync(join(projectPath, 'benchmark_profiler.gd'), 'extends Node\n');
        assert.deepEqual(findMissingAutoloadTargets(projectPath, projectContents), []);
    } finally {
        rmSync(projectPath, { recursive: true, force: true });
    }
});

test('tracked benchmark projects have no dangling autoloads', () => {
    const config = JSON.parse(readFileSync(join(testDirectory, 'scenes.json'), 'utf8'));
    const trackedBenchmarks = config.scenes.filter(scene => scene.id.startsWith('benchmark_'));

    for (const scene of trackedBenchmarks) {
        const projectPath = resolve(testDirectory, scene.path);
        const projectContents = readFileSync(join(projectPath, 'project.godot'), 'utf8');
        assert.deepEqual(findMissingAutoloadTargets(projectPath, projectContents), [], scene.id);
    }
});

test('heavy hosted scenes require explicit smoke profiles before capture', () => {
    const config = JSON.parse(readFileSync(join(testDirectory, 'scenes.json'), 'utf8'));
    const expectations = {
        benchmark_postfx: {
            injection: 'postfx_viewports: 2, postfx_size: 256',
            marker: '[SCENE-SMOKE] postfx viewports=2 size=256',
        },
        benchmark_batching: {
            injection: 'batching_meshes: 5000',
            marker: '[SCENE-SMOKE] batching meshes=5000 materials=10',
        },
    };

    for (const [sceneId, expectation] of Object.entries(expectations)) {
        const scene = config.scenes.find(candidate => candidate.id === sceneId);
        assert.ok(scene.capture_delay_ms >= 30000, sceneId);
        assert.ok(scene.capture_delay_ms < 180000, sceneId);
        assert.match(scene.inject_script, new RegExp(expectation.injection));
        assert.deepEqual(scene.pass_patterns, [expectation.marker]);
    }
});
