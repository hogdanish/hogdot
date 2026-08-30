/**
 * WebGPU Smoke Test — Headless Browser Validation
 *
 * Serves the exported Godot WebGPU project in headless Chrome and validates:
 * 1. WebGPU device initializes without errors
 * 2. No shader compilation failures (SPIR-V → WGSL conversion errors)
 * 3. No device-lost events
 * 4. Engine runs for the configured frame count and exits cleanly
 *
 * Usage:
 *   node smoke_test.mjs [export-dir] [options]
 *   node smoke_test.mjs ./export/
 *   node smoke_test.mjs ./export --scene=benchcompile --expect-prefix='[CGBENCH]'
 *
 * Options:
 *   --scene=<key>          gate/bench scene key, appended as ?scene=<key>
 *   --query=<raw>          extra query string, e.g. 'cgperf_ts' or 'hold'
 *   --expect-prefix=<p>    console prefix that carries the lifecycle lines
 *                          (default '[ShaderCoverage]'); the harness waits for
 *                          '<p> Starting' then '<p> PASS' / '<p> FAIL'
 *   --timeout=<seconds>    override the 120 s ceiling
 *
 * ⚠ The lifecycle prefix is a parameter and not a constant because the bench
 * scenes report measurements under '[CGBENCH]', not verdicts under
 * '[ShaderCoverage]'. Hardcoding one prefix is what made this harness
 * gate-only.
 *
 * Exit codes:
 *   0 = all shaders compiled, no errors
 *   1 = shader or WebGPU errors detected
 */

import { createServer } from 'http';
import { readFileSync, existsSync, statSync } from 'fs';
import { join, extname } from 'path';
import { fileURLToPath } from 'url';
import { dirname } from 'path';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

const argv = process.argv.slice(2);
const flags = new Map(
    argv
        .filter((a) => a.startsWith('--'))
        .map((a) => {
            const eq = a.indexOf('=');
            return eq === -1 ? [a.slice(2), ''] : [a.slice(2, eq), a.slice(eq + 1)];
        })
);
const positional = argv.filter((a) => !a.startsWith('--'));

const EXPORT_DIR = positional[0] || join(__dirname, 'export');
const TIMEOUT_MS = (Number(flags.get('timeout')) || 120) * 1000;
const EXPECT_PREFIX = flags.get('expect-prefix') || '[ShaderCoverage]';

// The scene dispatcher in shader_coverage.gd reads ?scene=<key>; --query carries anything else
// (?hold, ?cgperf_ts) through unchanged.
const QUERY_PARTS = [];
if (flags.has('scene')) {
    QUERY_PARTS.push(`scene=${encodeURIComponent(flags.get('scene'))}`);
}
if (flags.get('query')) {
    QUERY_PARTS.push(flags.get('query'));
}
const QUERY = QUERY_PARTS.length ? `?${QUERY_PARTS.join('&')}` : '';

const MIME_TYPES = {
    '.html': 'text/html',
    '.js': 'text/javascript',
    '.wasm': 'application/wasm',
    '.pck': 'application/octet-stream',
    '.png': 'image/png',
    '.svg': 'image/svg+xml',
    '.ico': 'image/x-icon',
    '.json': 'application/json',
    '.worker.js': 'text/javascript',
};

// ─── HTTP Server ──────────────────────────────────────────────────────────────

function startServer(dir) {
    return new Promise((resolve) => {
        const server = createServer((req, res) => {
            const url = req.url.split('?')[0];
            const filePath = join(dir, url === '/' ? 'index.html' : url);

            if (!existsSync(filePath) || statSync(filePath).isDirectory()) {
                res.writeHead(404);
                res.end('Not found');
                return;
            }

            const ext = extname(filePath);
            const headers = {
                'Content-Type': MIME_TYPES[ext] || 'application/octet-stream',
                'Cross-Origin-Opener-Policy': 'same-origin',
                'Cross-Origin-Embedder-Policy': 'require-corp',
            };

            // SharedArrayBuffer requires COOP/COEP headers
            res.writeHead(200, headers);
            res.end(readFileSync(filePath));
        });

        server.listen(0, '127.0.0.1', () => {
            resolve({ server, url: `http://127.0.0.1:${server.address().port}` });
        });
    });
}

// ─── Main ─────────────────────────────────────────────────────────────────────

async function main() {
    console.log('╔══════════════════════════════════════════════════════════╗');
    console.log('║   WebGPU Smoke Test — Headless Browser Validation        ║');
    console.log('╚══════════════════════════════════════════════════════════╝\n');

    // Verify export exists
    const indexPath = join(EXPORT_DIR, 'index.html');
    if (!existsSync(indexPath)) {
        console.error(`ERROR: Export not found at ${EXPORT_DIR}`);
        console.error('Run: godot --headless --path . --export-release "WebGPU" export/index.html');
        process.exit(1);
    }

    console.log(`Export directory: ${EXPORT_DIR}`);

    // Start server
    const { server, url } = await startServer(EXPORT_DIR);
    console.log(`Server: ${url}\n`);

    // Launch browser
    let chromium;
    try {
        const pw = await import('playwright');
        chromium = pw.chromium;
    } catch {
        console.error('ERROR: Playwright not installed.');
        console.error('  npm install playwright && npx playwright install chromium');
        server.close();
        process.exit(1);
    }

    console.log('Launching Chrome with WebGPU...');
    const browser = await chromium.launch({
        headless: false, // WebGPU requires headed mode on most systems
        args: [
            '--enable-unsafe-webgpu',
            '--enable-features=Vulkan,UseSkiaRenderer',
            '--disable-gpu-sandbox',
            '--use-angle=vulkan',
        ],
    });

    const page = await browser.newPage();

    // Collect errors
    const consoleErrors = [];
    const shaderErrors = [];
    const resultLines = [];
    let deviceLost = false;
    let engineStarted = false;
    let engineFinished = false;

    page.on('console', (msg) => {
        const text = msg.text();

        // Track shader errors
        if (text.includes('[SHADER]') || text.includes('Tint conversion') || text.includes('spirv error')) {
            shaderErrors.push(text);
            console.error(`  [SHADER ERROR] ${text}`);
        }

        // Track device lost
        if (text.includes('device lost') || text.includes('Device lost')) {
            deviceLost = true;
            console.error(`  [DEVICE LOST] ${text}`);
        }

        // Track engine lifecycle, under whichever prefix this run reports with.
        if (text.includes(`${EXPECT_PREFIX} Starting`)) {
            engineStarted = true;
            console.log('  Engine started.');
        }
        if (text.includes(`${EXPECT_PREFIX} PASS`)) {
            engineFinished = true;
            console.log('  Engine reports PASS.');
        }
        if (text.includes(`${EXPECT_PREFIX} FAIL`)) {
            engineFinished = true;
            console.error('  Engine reports FAIL.');
        }

        // Measurement lines are the whole point of a bench run, so echo them even without
        // VERBOSE — a bench whose numbers only appear behind a debug flag is not a bench.
        if (text.startsWith('[CGBENCH] ') || text.startsWith('[CGPERF] ')) {
            resultLines.push(text);
            console.log(`  ${text}`);
        }

        // Log significant messages
        if (msg.type() === 'error') {
            consoleErrors.push(text);
        }

        // Verbose output
        if (process.env.VERBOSE) {
            console.log(`  [${msg.type()}] ${text}`);
        }
    });

    page.on('pageerror', (err) => {
        consoleErrors.push(err.message);
        console.error(`  [PAGE ERROR] ${err.message}`);
    });

    // Navigate and wait
    console.log(`\nNavigating to ${url}${QUERY}...`);
    console.log(`Lifecycle prefix: ${EXPECT_PREFIX}`);
    await page.goto(`${url}${QUERY}`);

    // Wait for engine to finish or timeout
    const startTime = Date.now();
    while (!engineFinished && (Date.now() - startTime) < TIMEOUT_MS) {
        await new Promise(r => setTimeout(r, 1000));
        const elapsed = Math.floor((Date.now() - startTime) / 1000);
        if (elapsed % 10 === 0 && elapsed > 0) {
            console.log(`  Still waiting... ${elapsed}s elapsed`);
        }
    }

    await browser.close();
    server.close();

    // ─── Report ─────────────────────────────────────────────────────────────

    console.log('\n─── Results ─────────────────────────────────────────��─────\n');

    let exitCode = 0;

    if (!engineStarted) {
        console.error('  FAIL: Engine never started (WebGPU initialization may have failed)');
        exitCode = 1;
    }

    if (!engineFinished) {
        console.error('  FAIL: Engine did not complete within timeout');
        exitCode = 1;
    }

    if (deviceLost) {
        console.error('  FAIL: GPU device was lost');
        exitCode = 1;
    }

    if (shaderErrors.length > 0) {
        console.error(`  FAIL: ${shaderErrors.length} shader error(s):`);
        for (const err of shaderErrors.slice(0, 10)) {
            console.error(`    - ${err}`);
        }
        exitCode = 1;
    }

    if (exitCode === 0) {
        console.log('  PASS: All shaders compiled successfully, no errors detected.');
    }

    if (resultLines.length > 0) {
        console.log(`\n  Measurement lines: ${resultLines.length}`);
    }

    console.log(`\n  Console errors: ${consoleErrors.length}`);
    console.log(`  Shader errors:  ${shaderErrors.length}`);
    console.log(`  Device lost:    ${deviceLost}`);
    console.log(`  Engine started: ${engineStarted}`);
    console.log(`  Engine finished: ${engineFinished}`);

    process.exit(exitCode);
}

main().catch((e) => {
    console.error('Fatal:', e);
    process.exit(1);
});
