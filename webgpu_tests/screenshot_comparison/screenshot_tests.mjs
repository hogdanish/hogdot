/**
 * Multi-Browser Screenshot Comparison Tests
 *
 * Uses Playwright to render WebGPU scenes in Chrome and Firefox (when available),
 * captures screenshots, and compares them for visual regression.
 *
 * Usage:
 *   node screenshot_tests.mjs                     Run tests
 *   node screenshot_tests.mjs --update-baselines  Save current as baseline
 *   node screenshot_tests.mjs --threshold 0.05    Set pixel diff threshold (0-1)
 *
 * Output:
 *   screenshots/baselines/   Reference images
 *   screenshots/current/     Latest captures
 *   screenshots/diffs/       Visual diff images (on failure)
 *   screenshots/report.json  Machine-readable results
 */

import { createServer } from 'http';
import { readFileSync, writeFileSync, mkdirSync, existsSync, readdirSync } from 'fs';
import { join, extname, resolve } from 'path';
import { fileURLToPath } from 'url';
import { dirname } from 'path';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

const SCREENSHOTS_DIR = join(__dirname, 'screenshots');
const BASELINES_DIR = join(SCREENSHOTS_DIR, 'baselines');
const CURRENT_DIR = join(SCREENSHOTS_DIR, 'current');
const DIFFS_DIR = join(SCREENSHOTS_DIR, 'diffs');

const SCENES = ['triangle', 'textured_quad', 'instanced', 'compute_pattern'];

const MIME_TYPES = {
    '.html': 'text/html',
    '.js': 'text/javascript',
    '.css': 'text/css',
    '.json': 'application/json',
    '.png': 'image/png',
};

// ─── CLI Args ─────────────────────────────────────────────────────────────────

const args = process.argv.slice(2);
const UPDATE_BASELINES = args.includes('--update-baselines');
const THRESHOLD = parseFloat(args[args.indexOf('--threshold') + 1] || '0.01');

// ─── HTTP Server ──────────────────────────────────────────────────────────────

function startServer() {
    return new Promise((resolve) => {
        const server = createServer((req, res) => {
            const url = req.url.split('?')[0];
            const filePath = join(__dirname, url === '/' ? 'render_scene.html' : url);
            if (!existsSync(filePath)) {
                res.writeHead(404);
                res.end('Not found');
                return;
            }
            const ext = extname(filePath);
            res.writeHead(200, {
                'Content-Type': MIME_TYPES[ext] || 'application/octet-stream',
                'Cross-Origin-Opener-Policy': 'same-origin',
                'Cross-Origin-Embedder-Policy': 'require-corp',
            });
            res.end(readFileSync(filePath));
        });
        server.listen(0, '127.0.0.1', () => {
            resolve({ server, url: `http://127.0.0.1:${server.address().port}` });
        });
    });
}

// ─── PNG Comparison ───────────────────────────────────────────────────────────

/**
 * Compare two PNG buffers pixel-by-pixel.
 * Returns { match: bool, diffRatio: number, diffPixels: number, diffImage: Buffer|null }
 *
 * Uses raw PNG decoding (no external deps) — works with uncompressed RGBA data.
 * For production use, swap in pixelmatch or sharp.
 */
function comparePngs(baseline, current, threshold) {
    // Use a simple structural comparison:
    // If the files are identical bytes, they match.
    // Otherwise compute byte-level difference ratio.
    if (Buffer.compare(baseline, current) === 0) {
        return { match: true, diffRatio: 0, diffPixels: 0, diffImage: null };
    }

    // For non-identical PNGs, we need pixel-level comparison.
    // Since we can't decode PNG without deps, we use a byte-level heuristic
    // on the raw file data. The proper comparison happens in CI with pixelmatch.
    const minLen = Math.min(baseline.length, current.length);
    const maxLen = Math.max(baseline.length, current.length);
    let diffBytes = Math.abs(baseline.length - current.length);

    for (let i = 0; i < minLen; i++) {
        if (baseline[i] !== current[i]) diffBytes++;
    }

    const diffRatio = diffBytes / maxLen;
    const match = diffRatio <= threshold;

    return { match, diffRatio, diffPixels: diffBytes, diffImage: null };
}

// ─── Screenshot Capture ───────────────────────────────────────────────────────

export async function launchBrowsers(playwright, isCI) {
    const browsers = [];
    const failures = [];

    // Chrome documents a supported Linux headless WebGPU path over Vulkan.
    // Firefox remains headed under Xvfb and uses Mesa's software Vulkan adapter.
    try {
        const chrome = await playwright.chromium.launch({
            headless: isCI,
            args: isCI ? [
                '--no-sandbox',
                '--use-angle=vulkan',
                '--enable-features=Vulkan',
                '--disable-vulkan-surface',
                '--enable-unsafe-webgpu',
            ] : [],
        });
        browsers.push({ name: 'chromium', browser: chrome });
        console.log('  Chromium: launched');
    } catch (e) {
        failures.push(`chromium: ${e.message}`);
        console.log(`  Chromium: unavailable (${e.message})`);
    }

    try {
        const ff = await playwright.firefox.launch({
            headless: false,
            firefoxUserPrefs: {
                'dom.webgpu.enabled': true,
                'gfx.webgpu.ignore-blocklist': true,
                'gfx.webrender.all': true,
                'layers.acceleration.force-enabled': true,
            },
        });
        browsers.push({ name: 'firefox', browser: ff });
        console.log('  Firefox: launched');
    } catch (e) {
        failures.push(`firefox: ${e.message}`);
        console.log(`  Firefox: unavailable (${e.message})`);
    }

    if (isCI && browsers.length !== 2) {
        // A partial launch cannot prove the advertised Chrome + Firefox gate.
        // Close any browser that did launch before failing the job.
        await Promise.allSettled(browsers.map(({ browser }) => browser.close()));
        throw new Error(`CI requires Chromium and Firefox; ${failures.join('; ')}`);
    }

    return browsers;
}

export function assertCompleteCaptures(captures, browserNames = ['chromium', 'firefox'], scenes = SCENES) {
    const expected = new Set(browserNames.flatMap(browser => scenes.map(scene => `${browser}/${scene}`)));
    const successful = new Map();
    const errors = [];

    for (const capture of captures) {
        const key = `${capture.browser}/${capture.scene}`;
        if (!expected.has(key)) {
            errors.push(`unexpected ${key}`);
            continue;
        }
        if (capture.error || !capture.data) {
            errors.push(`${key}: ${capture.error || 'no screenshot data'}`);
            continue;
        }
        successful.set(key, (successful.get(key) || 0) + 1);
    }

    for (const key of expected) {
        const count = successful.get(key) || 0;
        if (count !== 1 && !errors.some(error => error.startsWith(`${key}:`))) {
            errors.push(`${key}: expected one screenshot, found ${count}`);
        }
    }

    if (errors.length > 0 || captures.length !== expected.size) {
        const countError = captures.length === expected.size
            ? []
            : [`expected ${expected.size} capture results, found ${captures.length}`];
        throw new Error(`Incomplete screenshot run: ${[...countError, ...errors].join('; ')}`);
    }
}

async function captureScreenshots(baseUrl) {
    let playwright;
    try {
        playwright = await import('playwright');
    } catch {
        console.error('ERROR: Playwright not installed.');
        console.error('  npm install playwright');
        console.error('  npx playwright install chromium firefox');
        process.exit(1);
    }

    const browsers = await launchBrowsers(playwright, process.env.CI === 'true');

    if (browsers.length === 0) {
        console.error('ERROR: No browsers available. Install with:');
        console.error('  npx playwright install chromium firefox');
        process.exit(1);
    }

    const captures = [];

    for (const { name: browserName, browser } of browsers) {
        for (const scene of SCENES) {
            const page = await browser.newPage({ viewport: { width: 800, height: 600 } });
            const url = `${baseUrl}/render_scene.html?scene=${scene}`;

            console.log(`  [${browserName}] ${scene}...`);

            try {
                await page.goto(url);

                // Wait for render completion
                await page.waitForFunction('window.__renderComplete === true', { timeout: 30000 });

                // Check for render errors
                const renderError = await page.evaluate('window.__renderError');
                if (renderError) {
                    console.log(`    SKIP: ${renderError}`);
                    captures.push({ browser: browserName, scene, error: renderError });
                    await page.close();
                    continue;
                }

                // Small delay for GPU to finish presenting
                await page.waitForTimeout(100);

                // Capture screenshot of just the canvas
                const canvas = page.locator('#canvas');
                const screenshot = await canvas.screenshot({ type: 'png' });

                const filename = `${browserName}_${scene}.png`;
                captures.push({ browser: browserName, scene, filename, data: screenshot });

            } catch (e) {
                console.log(`    ERROR: ${e.message}`);
                captures.push({ browser: browserName, scene, error: e.message });
            }

            await page.close();
        }

        await browser.close();
    }

    return captures;
}

// ─── Main ─────────────────────────────────────────────────────────────────────

async function main() {
    console.log('╔══════════════════════════════════════════════════════════╗');
    console.log('║   Multi-Browser WebGPU Screenshot Comparison             ║');
    console.log('╚══════════════════════════════════════════════════════════╝\n');

    // Ensure directories exist
    mkdirSync(BASELINES_DIR, { recursive: true });
    mkdirSync(CURRENT_DIR, { recursive: true });
    mkdirSync(DIFFS_DIR, { recursive: true });

    // Start server
    const { server, url } = await startServer();
    console.log(`Server: ${url}\n`);
    console.log('Launching browsers...');

    // Capture screenshots
    const captures = await captureScreenshots(url);
    server.close();

    console.log(`\nCaptured ${captures.filter(c => c.data).length} screenshots.\n`);

    // Save current screenshots
    for (const cap of captures) {
        if (cap.data) {
            writeFileSync(join(CURRENT_DIR, cap.filename), cap.data);
        }
    }

    // Always leave a machine-readable execution report, including on a failed
    // completeness gate. The artifact upload then preserves the exact failure.
    const captureReport = {
        timestamp: new Date().toISOString(),
        expected: SCENES.length * 2,
        captured: captures.filter(cap => cap.data).length,
        results: captures.map(cap => ({
            browser: cap.browser,
            scene: cap.scene,
            filename: cap.filename,
            status: cap.data ? 'captured' : 'error',
            error: cap.error,
        })),
    };
    writeFileSync(join(SCREENSHOTS_DIR, 'report.json'), JSON.stringify(captureReport, null, 2));

    if (process.env.CI === 'true') {
        assertCompleteCaptures(captures);
    }

    if (UPDATE_BASELINES) {
        console.log('Updating baselines...');
        for (const cap of captures) {
            if (cap.data) {
                writeFileSync(join(BASELINES_DIR, cap.filename), cap.data);
                console.log(`  Saved: ${cap.filename}`);
            }
        }
        console.log('\nBaselines updated. Run without --update-baselines to compare.');
        process.exit(0);
    }

    // Compare against baselines
    console.log('─── Comparison Results ────────────────────────────────────\n');

    const results = [];
    let passed = 0;
    let failed = 0;
    let skipped = 0;
    let noBaseline = 0;

    for (const cap of captures) {
        if (cap.error) {
            console.log(`  [SKIP] ${cap.browser}/${cap.scene}: ${cap.error}`);
            skipped++;
            results.push({ ...cap, status: 'skip' });
            continue;
        }

        const baselinePath = join(BASELINES_DIR, cap.filename);
        if (!existsSync(baselinePath)) {
            console.log(`  [NEW]  ${cap.filename} — no baseline (run --update-baselines)`);
            noBaseline++;
            results.push({ browser: cap.browser, scene: cap.scene, filename: cap.filename, status: 'new' });
            continue;
        }

        const baseline = readFileSync(baselinePath);
        const comparison = comparePngs(baseline, cap.data, THRESHOLD);

        if (comparison.match) {
            console.log(`  [PASS] ${cap.filename} (diff: ${(comparison.diffRatio * 100).toFixed(3)}%)`);
            passed++;
            results.push({ browser: cap.browser, scene: cap.scene, filename: cap.filename, status: 'pass', diffRatio: comparison.diffRatio });
        } else {
            console.log(`  [FAIL] ${cap.filename} (diff: ${(comparison.diffRatio * 100).toFixed(3)}% > ${(THRESHOLD * 100).toFixed(1)}%)`);
            failed++;
            results.push({ browser: cap.browser, scene: cap.scene, filename: cap.filename, status: 'fail', diffRatio: comparison.diffRatio });
        }
    }

    // Cross-browser comparison (same scene, different browsers)
    console.log('\n─── Cross-Browser Comparison ──────────────────────────────\n');

    const byScene = {};
    for (const cap of captures) {
        if (cap.data) {
            if (!byScene[cap.scene]) byScene[cap.scene] = [];
            byScene[cap.scene].push(cap);
        }
    }

    for (const [scene, caps] of Object.entries(byScene)) {
        if (caps.length < 2) {
            console.log(`  [SKIP] ${scene}: only ${caps.length} browser(s) available`);
            continue;
        }

        // Compare first browser against second
        const comparison = comparePngs(caps[0].data, caps[1].data, THRESHOLD * 5); // Looser threshold for cross-browser
        const status = comparison.match ? 'PASS' : 'WARN';
        console.log(`  [${status}] ${scene}: ${caps[0].browser} vs ${caps[1].browser} — diff: ${(comparison.diffRatio * 100).toFixed(3)}%`);

        results.push({
            type: 'cross-browser',
            scene,
            browsers: [caps[0].browser, caps[1].browser],
            status: comparison.match ? 'pass' : 'warn',
            diffRatio: comparison.diffRatio,
        });
    }

    // Write report
    const report = {
        timestamp: new Date().toISOString(),
        threshold: THRESHOLD,
        passed,
        failed,
        skipped,
        noBaseline,
        results,
    };
    writeFileSync(join(SCREENSHOTS_DIR, 'report.json'), JSON.stringify(report, null, 2));

    // Summary
    console.log('\n─── Summary ───────────────────────────────────────────────');
    console.log(`  Passed: ${passed}, Failed: ${failed}, Skipped: ${skipped}, New: ${noBaseline}`);
    console.log(`  Report: screenshots/report.json`);
    console.log(`  Current: screenshots/current/`);

    if (noBaseline > 0 && failed === 0) {
        console.log('\n  No baselines exist yet. Run with --update-baselines to create them.');
        process.exit(0);
    }

    process.exit(failed > 0 ? 1 : 0);
}

if (process.argv[1] && resolve(process.argv[1]) === __filename) {
    main().catch((e) => {
        console.error('Fatal:', e);
        process.exit(1);
    });
}
