/**
 * WebGPU Smoke Test — Browser Validation
 *
 * Serves the exported Godot WebGPU project in headed Chrome and validates:
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
 *   --dump-cgperf[=<path>] read window.__cgPerf out of the live page just before
 *                          the browser closes and write it as JSON (default
 *                          ./cgperf-dump.json). This is the channel-presence
 *                          gate: a template whose driver telemetry never
 *                          installed dumps {"present": false} and FAILS the run.
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
import { readFileSync, writeFileSync, existsSync, statSync } from 'fs';
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
const DUMP_CGPERF = flags.has('dump-cgperf')
    ? (flags.get('dump-cgperf') || join(__dirname, 'cgperf-dump.json'))
    : null;

// How much of each unbounded ring the dump keeps. The frame ring is 3600 x 13
// doubles; serializing all of it produces a ~2 MB file nobody reads, so the dump
// carries whole-run aggregates plus the newest FRAME_TAIL rows decoded by name.
const FRAME_TAIL = 24;
const COMPILE_TAIL = 40;

// ⚠ The Chrome launch args are PLATFORM-SPECIFIC and getting them wrong is silent.
// `--use-angle=vulkan --enable-features=Vulkan,UseSkiaRenderer` is what a Linux CI
// box needs; on macOS the same flags push Chrome off Metal and onto SwiftShader —
// measured 2026-08-30, same machine, same page: with those flags the adapter is
// google/swiftshader (a CPU rasteriser), without them it is apple/metal-3. Every
// number this harness produced on macOS before this was therefore software-rendered.
// Override with --gpu-args='<space separated>' when a specific backend is the point.
const DEFAULT_GPU_ARGS = process.platform === 'darwin'
    ? ['--enable-unsafe-webgpu']
    : ['--enable-unsafe-webgpu', '--enable-features=Vulkan,UseSkiaRenderer', '--disable-gpu-sandbox', '--use-angle=vulkan'];
const LAUNCH_ARGS = flags.has('gpu-args')
    ? flags.get('gpu-args').split(/\s+/).filter(Boolean)
    : DEFAULT_GPU_ARGS;

// Adapters that mean "no GPU took part in this run". A gate may legitimately run on
// one; a measurement never may, so the run says so out loud rather than leaving it
// to whoever reads the numbers later.
const SOFTWARE_ADAPTERS = /swiftshader|llvmpipe|lavapipe|software/i;

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

// ─── window.__cgPerf dump ─────────────────────────────────────────────────────

/**
 * Read the driver's telemetry channel out of the live page.
 *
 * ⚠ Everything that touches `__cgPerf.frames` has to run INSIDE the page. `.buf`
 * is a Float64Array view over the wasm heap: it does not survive Playwright's
 * structured clone, and -sALLOW_MEMORY_GROWTH=1 means it may be detached the
 * moment after it is handed out. The page function decodes it to plain numbers
 * on the spot and never holds the view across a statement that could allocate.
 */
async function dumpCgPerf(page, frameTail, compileTail) {
    return page.evaluate(
        ({ frameTail, compileTail }) => {
            const ch = window.__cgPerf;
            if (!ch) {
                return { present: false };
            }
            const out = {
                present: true,
                version: ch.version,
                build: ch.build,
                counters: ch.counters,
                ts: ch.ts,
                frames_schema: ch.frames_schema,
                frames_schema_note: ch.frames_schema_note,
            };

            // Frame ring. Oldest→newest is buf[((head - count + i) % cap) * stride + f]
            // (deviation D-5 — the fork owns the ring mechanics and documents this shape).
            const f = ch.frames;
            const { head, cap, stride, count, buf } = f;
            const names = ch.frames_schema;
            const idx = (i, field) => (((head - count + i) % cap) * stride) + field;

            const col = (field) => {
                const v = new Array(count);
                for (let i = 0; i < count; i++) {
                    v[i] = buf[idx(i, field)];
                }
                return v;
            };
            const pct = (sorted, p) =>
                sorted.length ? sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * p))] : null;

            const stats = {};
            for (let field = 0; field < stride; field++) {
                const v = col(field);
                const sorted = v.slice().sort((a, b) => a - b);
                let sum = 0;
                for (const x of v) {
                    sum += x;
                }
                stats[names[field]] = {
                    min: sorted[0] ?? null,
                    p50: pct(sorted, 0.5),
                    p95: pct(sorted, 0.95),
                    max: sorted[sorted.length - 1] ?? null,
                    sum,
                };
            }

            const tail = [];
            for (let i = Math.max(0, count - frameTail); i < count; i++) {
                const row = {};
                for (let field = 0; field < stride; field++) {
                    row[names[field]] = buf[idx(i, field)];
                }
                tail.push(row);
            }

            // fence_lag is signed on purpose: negative means the driver force-signalled
            // a fence the GPU had not reported done on, and the magnitude is how far
            // the CPU had run ahead. Counting the sign split is the whole point.
            let negLag = 0;
            let posLag = 0;
            for (const x of col(names.indexOf('fence_lag'))) {
                if (x < 0) {
                    negLag++;
                } else if (x > 0) {
                    posLag++;
                }
            }

            out.frames = {
                head,
                cap,
                stride,
                count,
                fence_lag_negative_frames: negLag,
                fence_lag_positive_frames: posLag,
                stats,
                tail,
            };

            out.compiles = {
                length: ch.compiles.length,
                capped_at: 512,
                tail: ch.compiles.slice(-compileTail),
            };
            out.events = { length: ch.events.length, all: ch.events.slice() };
            return out;
        },
        { frameTail, compileTail }
    );
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
    console.log(`GPU args: ${LAUNCH_ARGS.join(' ') || '(none)'}`);
    const browser = await chromium.launch({
        headless: false, // WebGPU requires headed mode on most systems
        args: LAUNCH_ARGS,
    });

    const page = await browser.newPage();

    // Collect errors
    const consoleErrors = [];
    const shaderErrors = [];
    const resultLines = [];
    let deviceLost = false;
    let deviceLostAfterVerdict = 0;
    let engineStarted = false;
    let engineFinished = false;

    page.on('console', (msg) => {
        const text = msg.text();

        // Track shader errors
        if (text.includes('[SHADER]') || text.includes('Tint conversion') || text.includes('spirv error')) {
            shaderErrors.push(text);
            console.error(`  [SHADER ERROR] ${text}`);
        }

        // Track device lost.
        // ⚠ Only BEFORE the scene has reported its verdict. A scene that does not
        // ?hold calls quit() the moment it passes, the wasm instance goes away, and
        // the always-on device-lost listener faithfully reports "A valid external
        // Instance reference no longer exists" — teardown, not a failure. Counting
        // that as a lost device turns a green gate red on whichever machine is slow
        // enough to let the quit land inside the harness's 1 s poll window, which is
        // a flake that depends on how fast the GPU is.
        if (text.includes('device lost') || text.includes('Device lost')) {
            if (engineFinished) {
                deviceLostAfterVerdict++;
            } else {
                deviceLost = true;
                console.error(`  [DEVICE LOST] ${text}`);
            }
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

    // Read the channel BEFORE the browser goes away — there is no other moment.
    let cgPerf = null;
    let cgPerfError = null;
    if (DUMP_CGPERF) {
        try {
            cgPerf = await dumpCgPerf(page, FRAME_TAIL, COMPILE_TAIL);
            writeFileSync(DUMP_CGPERF, JSON.stringify(cgPerf, null, 2));
            console.log(`\n  __cgPerf dumped to ${DUMP_CGPERF}`);
        } catch (e) {
            cgPerfError = e.message;
            console.error(`  [CGPERF DUMP ERROR] ${e.message}`);
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

    // The channel-presence gate. Asked for and absent is a build that shipped
    // without its telemetry — exactly the silent regression this dump exists to
    // catch, so it fails the run rather than printing a note.
    if (DUMP_CGPERF) {
        if (cgPerfError) {
            console.error(`  FAIL: window.__cgPerf could not be read: ${cgPerfError}`);
            exitCode = 1;
        } else if (!cgPerf || !cgPerf.present) {
            console.error('  FAIL: window.__cgPerf was never installed by the driver.');
            exitCode = 1;
        } else if (!cgPerf.build || !cgPerf.build.engine_commit) {
            console.error('  FAIL: window.__cgPerf.build has no engine_commit (boot blob never filled).');
            exitCode = 1;
        } else {
            const c = cgPerf.counters || {};
            const ad = cgPerf.build.adapter || {};
            console.log(`  __cgPerf: engine=${cgPerf.build.engine_commit} threads=${cgPerf.build.threads ? 1 : 0} ` +
                `adapter=${ad.vendor}/${ad.architecture} ` +
                `frames=${cgPerf.frames.count} compiles=${cgPerf.compiles.length} events=${cgPerf.events.length} ` +
                `baked=${c.baked_wgsl_hit}/${c.baked_wgsl_hit + c.baked_wgsl_miss}`);
            // A software adapter still gates correctness, but no timing taken on it
            // means anything. Say it here so it can never be inferred from silence.
            if (SOFTWARE_ADAPTERS.test(`${ad.vendor} ${ad.architecture} ${ad.device} ${ad.description}`)) {
                console.warn('  WARNING: this run used a SOFTWARE adapter ' +
                    `(${ad.vendor}/${ad.architecture}) — correctness only, every timing is meaningless.`);
            }
            // An empty frame ring with a live channel is the exact shape of the
            // clock bug that made this instrument silently dead; never let it pass
            // as "the run was short".
            if (cgPerf.frames.count === 0) {
                console.error('  FAIL: __cgPerf installed but its frame ring is empty — begin_segment never recorded.');
                exitCode = 1;
            }
        }
    }

    if (exitCode === 0) {
        console.log('  PASS: All shaders compiled successfully, no errors detected.');
    }

    if (resultLines.length > 0) {
        console.log(`\n  Measurement lines: ${resultLines.length}`);
    }

    console.log(`\n  Console errors: ${consoleErrors.length}`);
    console.log(`  Shader errors:  ${shaderErrors.length}`);
    console.log(`  Device lost:    ${deviceLost}${deviceLostAfterVerdict ? ` (+${deviceLostAfterVerdict} at teardown, ignored)` : ''}`);
    console.log(`  Engine started: ${engineStarted}`);
    console.log(`  Engine finished: ${engineFinished}`);

    process.exit(exitCode);
}

main().catch((e) => {
    console.error('Fatal:', e);
    process.exit(1);
});
