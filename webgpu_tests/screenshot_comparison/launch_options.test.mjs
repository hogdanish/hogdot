import assert from 'node:assert/strict';
import test from 'node:test';

import { assertCompleteCaptures, launchBrowsers } from './screenshot_tests.mjs';

function fakePlaywright(calls, rejectedBrowser = null) {
    const browser = {
        close: async () => {
            calls.closed = (calls.closed ?? 0) + 1;
        },
    };
    return {
        chromium: {
            launch: async (options) => {
                calls.chromium = options;
                if (rejectedBrowser === 'chromium') {
                    throw new Error('simulated Chromium launch failure');
                }
                return browser;
            },
        },
        firefox: {
            launch: async (options) => {
                calls.firefox = options;
                if (rejectedBrowser === 'firefox') {
                    throw new Error('simulated Firefox launch failure');
                }
                return browser;
            },
        },
    };
}

test('CI launches Chromium headless over Vulkan and Firefox headed over Mesa', async () => {
    const calls = {};

    const browsers = await launchBrowsers(fakePlaywright(calls), true);

    assert.equal(browsers.length, 2);
    assert.equal(calls.chromium.headless, true);
    assert.equal(calls.firefox.headless, false);
    assert.deepEqual(calls.chromium.args, [
        '--no-sandbox',
        '--use-angle=vulkan',
        '--enable-features=Vulkan',
        '--disable-vulkan-surface',
        '--enable-unsafe-webgpu',
    ]);
    assert.deepEqual(calls.firefox.firefoxUserPrefs, {
        'dom.webgpu.enabled': true,
        'gfx.webgpu.ignore-blocklist': true,
        'gfx.webrender.all': true,
        'layers.acceleration.force-enabled': true,
    });
});

test('local runs keep both screenshot browsers headed', async () => {
    const calls = {};

    await launchBrowsers(fakePlaywright(calls), false);

    assert.equal(calls.chromium.headless, false);
    assert.equal(calls.firefox.headless, false);
});

test('CI fails closed when one screenshot browser cannot launch', async () => {
    const calls = {};

    await assert.rejects(
        launchBrowsers(fakePlaywright(calls, 'firefox'), true),
        /CI requires Chromium and Firefox; firefox: simulated Firefox launch failure/,
    );
    assert.equal(calls.closed, 1);
});

test('local runs retain a browser when the other cannot launch', async () => {
    const calls = {};

    const browsers = await launchBrowsers(fakePlaywright(calls, 'firefox'), false);

    assert.deepEqual(browsers.map(({ name }) => name), ['chromium']);
});

const browserNames = ['chromium', 'firefox'];
const scenes = ['triangle', 'textured_quad'];

function completeCaptures() {
    return browserNames.flatMap(browser => scenes.map(scene => ({ browser, scene, data: Buffer.from('png') })));
}

test('CI capture completeness accepts exactly one image for every browser and scene', () => {
    assert.doesNotThrow(() => assertCompleteCaptures(completeCaptures(), browserNames, scenes));
});

test('CI capture completeness rejects a zero-capture run', () => {
    const captures = browserNames.flatMap(browser => scenes.map(scene => ({
        browser,
        scene,
        error: 'No GPU adapter',
    })));

    assert.throws(
        () => assertCompleteCaptures(captures, browserNames, scenes),
        /Incomplete screenshot run:.*chromium\/triangle: No GPU adapter/,
    );
});

test('CI capture completeness rejects a partial capture run', () => {
    const captures = completeCaptures();
    captures.pop();

    assert.throws(
        () => assertCompleteCaptures(captures, browserNames, scenes),
        /expected 4 capture results, found 3; firefox\/textured_quad: expected one screenshot, found 0/,
    );
});
