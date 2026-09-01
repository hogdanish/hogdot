/**
 * Tests the exported web shell's renderer-specific feature preflight.
 */

import { readFileSync } from 'node:fs';
import vm from 'node:vm';

import { assert, describe, it } from './test_harness.mjs';

const featuresPath = new URL('../../platform/web/js/engine/features.js', import.meta.url);
const featuresSource = readFileSync(featuresPath, 'utf8');
const exportShellPath = new URL('../../misc/dist/html/full-size.html', import.meta.url);
const exportShellSource = readFileSync(exportShellPath, 'utf8');

function getMissingFeatures({ webglAvailable, webgl2 }) {
    const context = {
        document: {
            createElement: () => ({
                getContext: () => webglAvailable ? {} : null,
            }),
        },
        window: {
            fetch: () => {},
            Response: function Response() {},
            isSecureContext: true,
        },
    };
    context.window.Response.prototype.body = {};

    vm.runInNewContext(
        `${featuresSource}\nglobalThis.FeaturesUnderTest = Features;`,
        context,
    );

    return context.FeaturesUnderTest.getMissingFeatures({
        threads: false,
        webgl2,
    });
}

export function runTests() {
    describe('Web renderer feature preflight', () => {
        it('does not require WebGL2 for a WebGPU export', () => {
            const missing = getMissingFeatures({
                webglAvailable: false,
                webgl2: false,
            });
            assert.ok(!missing.some(feature => feature.startsWith('WebGL2')));
        });

        it('still requires WebGL2 for a compatibility export', () => {
            const missing = getMissingFeatures({
                webglAvailable: false,
                webgl2: true,
            });
            assert.ok(missing.some(feature => feature.startsWith('WebGL2')));
        });

        it('selects the renderer-specific contract in the exported shell', () => {
            assert.ok(exportShellSource.includes(
                "webgl2: GODOT_RENDERING_DRIVER !== 'webgpu'",
            ));
        });
    });
}
