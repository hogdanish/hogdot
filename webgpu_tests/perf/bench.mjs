#!/usr/bin/env node
/**
 * hogdot perf runner — drives the exported perf bed through real Chrome and records results.
 *
 *   node webgpu_tests/perf/bench.mjs --export main=exports/hogdot-main --export gw462=exports/gw462 \
 *        --scenes world,draws --tag baseline [--throttle 4] [--query chars=40] [--runs 2]
 *
 * Options
 *   --export label=dir   an exported perf bed (repeatable). Results are keyed by label.
 *   --scenes a,b,c       scene keys (see project/main.gd). Default: all.
 *   --query k=v&k2=v2    extra query parameters passed to every scene.
 *   --throttle N         CDP CPU throttling rate (4 ≈ a mid-range laptop's CPU budget). Default 1.
 *   --tag NAME           results go to results/<tag>/. Default: timestamp.
 *   --runs N             repeat each (label, scene) N times; the table shows the median run.
 *   --timeout S          per-run ceiling in seconds (default 300).
 *   --stall S            abort a run when no [CGBENCH] line has arrived for S seconds (default 60)
 *                        and record it as STALLED with the console tail.
 *   --chromium           use Playwright's bundled Chromium instead of installed Google Chrome.
 *   --fresh              new browser process per run (cold GPU shader cache; use for spawn/load).
 *   --headless           try headless (WebGPU may be unavailable; default is a visible window).
 *   --skip-existing      skip a (label, scene) whose JSON already exists in results/<tag>/.
 *   --screenshot         save a PNG of the page after the verdict (pass `hold` in --query).
 *   --grep REGEX         keep every console line matching REGEX in the run's JSON (`grepped`).
 *   --profile            record a CDP CPU profile of each run (results/<tag>/*.cpuprofile) and
 *                        print the top self-time functions (wasm names need a template built
 *                        with debug_symbols=yes, i.e. --profiling-funcs).
 *
 * Output: one JSON per run under results/<tag>/ plus a Markdown table on stdout.
 *
 * ⚠ The page must stay visible: Chrome stops requestAnimationFrame for hidden tabs and pauses
 *   rendering of fully occluded windows on macOS. The runner brings its window to the front and
 *   every phase line carries `visible=`; a phase with visible=0 is marked stale by the scene.
 */

import { createServer } from 'http';
import { readFileSync, writeFileSync, existsSync, statSync, mkdirSync } from 'fs';
import { join, extname, dirname, resolve } from 'path';
import { fileURLToPath } from 'url';
import { createRequire } from 'module';
import { execFileSync } from 'child_process';

const __dirname = dirname(fileURLToPath(import.meta.url));
const argv = process.argv.slice(2);

function opt(name, def) {
    const i = argv.indexOf(`--${name}`);
    if (i === -1) {
        return def;
    }
    const v = argv[i + 1];
    return v === undefined || v.startsWith('--') ? true : v;
}
function optAll(name) {
    const out = [];
    for (let i = 0; i < argv.length; i++) {
        if (argv[i] === `--${name}` && argv[i + 1]) {
            out.push(argv[i + 1]);
        }
    }
    return out;
}

const EXPORTS = optAll('export').map((s) => {
    const eq = s.indexOf('=');
    if (eq === -1) {
        return { label: s.replace(/[\\/]+$/, '').split(/[\\/]/).pop(), dir: resolve(s) };
    }
    return { label: s.slice(0, eq), dir: resolve(s.slice(eq + 1)) };
});
const ALL_SCENES = ['world', 'sprites3d', 'particles', 'draws', 'ui', 'postfx', 'shadows', 'spawn'];
const SCENES = String(opt('scenes', ALL_SCENES.join(','))).split(',').filter(Boolean);
const QUERY = opt('query', '');
const THROTTLE = Number(opt('throttle', 1));
const RUNS = Number(opt('runs', 1));
const TIMEOUT_MS = Number(opt('timeout', 300)) * 1000;
const STALL_MS = Number(opt('stall', 60)) * 1000;
const TAG = String(opt('tag', new Date().toISOString().replace(/[:T]/g, '-').slice(0, 16)));
const USE_CHROMIUM = opt('chromium', false) === true;
const FRESH = opt('fresh', false) === true;
const HEADLESS = opt('headless', false) === true;
const PROFILE = opt('profile', false) === true;
const SCREENSHOT = opt('screenshot', false) === true;
const SKIP_EXISTING = opt('skip-existing', false) === true;
const GREP = opt('grep', null) ? new RegExp(String(opt('grep', null))) : null;
const OUT_DIR = join(__dirname, 'results', TAG);

if (EXPORTS.length === 0) {
    console.error('need at least one --export label=dir');
    process.exit(2);
}
for (const e of EXPORTS) {
    if (!existsSync(join(e.dir, 'index.html'))) {
        console.error(`no index.html in ${e.dir} (label ${e.label})`);
        process.exit(2);
    }
}
mkdirSync(OUT_DIR, { recursive: true });

const MIME = {
    '.html': 'text/html',
    '.js': 'text/javascript',
    '.wasm': 'application/wasm',
    '.pck': 'application/octet-stream',
    '.png': 'image/png',
    '.json': 'application/json',
};

function serve(dir) {
    return new Promise((res) => {
        const server = createServer((req, r) => {
            const p = join(dir, req.url.split('?')[0] === '/' ? 'index.html' : req.url.split('?')[0]);
            if (!existsSync(p) || statSync(p).isDirectory()) {
                r.writeHead(404);
                r.end('nope');
                return;
            }
            r.writeHead(200, {
                'Content-Type': MIME[extname(p)] || 'application/octet-stream',
                'Cross-Origin-Opener-Policy': 'same-origin',
                'Cross-Origin-Embedder-Policy': 'require-corp',
                'Cache-Control': 'no-store',
            });
            r.end(readFileSync(p));
        });
        server.listen(0, '127.0.0.1', () => res({ server, url: `http://127.0.0.1:${server.address().port}/` }));
    });
}

function parseLine(text) {
    // "[CGBENCH] <tag> k=v k=v …"
    const parts = text.slice('[CGBENCH] '.length).split(' ');
    const tag = parts.shift();
    const fields = {};
    for (const kv of parts) {
        const eq = kv.indexOf('=');
        if (eq === -1) {
            continue;
        }
        const k = kv.slice(0, eq);
        const v = kv.slice(eq + 1);
        fields[k] = v === 'na' ? null : (v !== '' && !Number.isNaN(Number(v)) ? Number(v) : v);
    }
    return { tag, fields };
}

async function loadPlaywright() {
    const candidates = [
        join(__dirname, 'node_modules'),
        join(__dirname, '..', 'scene_smoketest', 'node_modules'),
        join(__dirname, '..', 'test_project', 'node_modules'),
    ];
    for (const c of candidates) {
        try {
            const req = createRequire(join(c, 'x.js'));
            return req('playwright');
        } catch {
            // next
        }
    }
    throw new Error('playwright not found; npm install playwright in webgpu_tests/scene_smoketest');
}

async function launch(pw) {
    const args = ['--enable-unsafe-webgpu', '--autoplay-policy=no-user-gesture-required'];
    const base = { headless: HEADLESS, args };
    if (!USE_CHROMIUM) {
        try {
            return await pw.chromium.launch({ ...base, channel: 'chrome' });
        } catch (e) {
            console.warn(`Google Chrome channel unavailable (${e.message.split('\n')[0]}); using bundled Chromium`);
        }
    }
    return pw.chromium.launch(base);
}

async function pageDump(page) {
    return page.evaluate(async () => {
        const out = {};
        const ch = window.__cgPerf;
        if (ch) {
            out.cgperf = {
                build: ch.build,
                counters: ch.counters,
                ts: ch.ts,
                compiles: ch.compiles.length,
                compile_ms_total: ch.compiles.reduce((s, c) => s + c.ms, 0),
                compile_top: ch.compiles.slice().sort((a, b) => b.ms - a.ms).slice(0, 8),
                translate_top: ch.compiles.filter((c) => c.translate_ms > 0).sort((a, b) => b.translate_ms - a.translate_ms).slice(0, 12).map((c) => ({ label: c.label, translate_ms: c.translate_ms, baked: c.baked })),
                // Which shader families were NOT served by the bake (module records with baked=false),
                // keyed by the shader name inside the module label "mod:<name>:<variant>:stg<N>".
                unbaked: (() => {
                    const m = {};
                    for (const c of ch.compiles) {
                        if (c.kind === 'module' && !c.baked) {
                            const name = (c.label.split(':')[1] || c.label);
                            m[name] = (m[name] || 0) + 1;
                        }
                    }
                    return m;
                })(),
                baked_modules: ch.compiles.filter((c) => c.kind === 'module' && c.baked).length,
                modules_by_label: (() => {
                    const m = {};
                    for (const c of ch.compiles) {
                        if (c.kind === 'module') {
                            const k = `${c.label}${c.baked ? '' : ' UNBAKED'}`;
                            m[k] = (m[k] || 0) + 1;
                        }
                    }
                    return m;
                })(),
                events: ch.events.slice(),
            };
        }
        try {
            const a = await navigator.gpu.requestAdapter();
            const info = a && (a.info || (a.requestAdapterInfo && (await a.requestAdapterInfo())));
            out.adapter = info ? { vendor: info.vendor, architecture: info.architecture, device: info.device, description: info.description } : null;
        } catch {
            out.adapter = null;
        }
        out.ua = navigator.userAgent;
        out.dpr = window.devicePixelRatio;
        out.longtasks = window.__bench ? window.__bench.lt.length / 2 : null;
        out.frames_seen = window.__bench ? window.__bench.rafCount() : null;
        out.write_by_label = window.__bench && window.__bench.byLabelTop ? window.__bench.byLabelTop(16) : null;
        return out;
    });
}

async function runOne(browser, pw, exp, scene, runIdx) {
    const { server, url } = await serve(exp.dir);
    const q = new URLSearchParams(QUERY);
    q.set('scene', scene);
    const target = `${url}?${q.toString()}`;
    const context = await browser.newContext({ viewport: { width: 1280, height: 720 } });
    const page = await context.newPage();
    const cdp = await context.newCDPSession(page);
    if (THROTTLE > 1) {
        await cdp.send('Emulation.setCPUThrottlingRate', { rate: THROTTLE });
    }
    const lines = [];
    const raw = [];
    const errors = [];
    const tail = [];
    const grepped = [];
    let verdict = null;
    let resolveDone;
    const done = new Promise((r) => (resolveDone = r));
    let lastProgress = Date.now();
    const stallTimer = setInterval(() => {
        if (Date.now() - lastProgress > STALL_MS) {
            verdict = `STALLED (no [CGBENCH] line for ${(STALL_MS / 1000).toFixed(0)} s)`;
            resolveDone();
        }
    }, 1000);
    page.on('console', (msg) => {
        const text = msg.text();
        tail.push(`[${msg.type()}] ${text.slice(0, 300)}`);
        if (GREP && GREP.test(text) && grepped.length < 5000) {
            grepped.push(text.slice(0, 400));
        }
        if (tail.length > 40) {
            tail.shift();
        }
        if (text.startsWith('[CGBENCH] ')) {
            lastProgress = Date.now();
            if (text.startsWith('[CGBENCH] PASS') || text.startsWith('[CGBENCH] FAIL')) {
                verdict = text;
                resolveDone();
            } else if (!text.startsWith('[CGBENCH] Starting')) {
                lines.push(parseLine(text));
            }
            console.log(`    ${text}`);
        } else if (text.startsWith('[PERF]') || text.startsWith('[CGPERF]')) {
            raw.push(text);
        } else if (msg.type() === 'error') {
            errors.push(text);
        }
    });
    page.on('pageerror', (e) => errors.push(`pageerror: ${e.message}`));
    const t0 = Date.now();
    if (PROFILE) {
        await cdp.send('Profiler.enable');
        await cdp.send('Profiler.setSamplingInterval', { interval: 250 });
        await cdp.send('Profiler.start');
    }
    await page.goto(target);
    await page.bringToFront();
    const timer = setTimeout(resolveDone, TIMEOUT_MS);
    await done;
    clearTimeout(timer);
    clearInterval(stallTimer);
    if (SCREENSHOT) {
        // Needs ?hold in --query so the scene stays on screen after its verdict.
        try {
            const shot = join(OUT_DIR, `${exp.label}.${scene}.png`);
            await page.screenshot({ path: shot });
            console.log(`    screenshot: ${shot}`);
        } catch (e) {
            errors.push(`screenshot: ${e.message}`);
        }
    }
    if (!verdict || !verdict.startsWith('[CGBENCH]')) {
        console.log(`    !! ${verdict || 'TIMEOUT'} — console tail:`);
        for (const t of tail.slice(-12)) {
            console.log(`       ${t}`);
        }
    }
    let profileSummary = null;
    if (PROFILE) {
        try {
            const { profile } = await cdp.send('Profiler.stop');
            const suffix0 = THROTTLE > 1 ? `.t${THROTTLE}` : '';
            const pfile = join(OUT_DIR, `${exp.label}.${scene}${suffix0}${RUNS > 1 ? `.r${runIdx}` : ''}.cpuprofile`);
            writeFileSync(pfile, JSON.stringify(profile));
            profileSummary = summarizeProfile(profile);
            console.log(`    profile: ${pfile}`);
            console.log(profileSummary.text);
        } catch (e) {
            errors.push(`profile: ${e.message}`);
        }
    }
    let dump = {};
    try {
        // A hung page never answers evaluate(); bound it or the whole suite stops here.
        dump = await Promise.race([
            pageDump(page),
            new Promise((_, rej) => setTimeout(() => rej(new Error('page dump timed out (page hung)')), 15000)),
        ]);
    } catch (e) {
        errors.push(`dump: ${e.message}`);
    }
    if (dump.cgperf && dump.cgperf.unbaked) {
        const u = Object.entries(dump.cgperf.unbaked).sort((a, b) => b[1] - a[1]);
        console.log(`    baked modules: ${dump.cgperf.baked_modules}; unbaked modules by shader: ${u.map(([k, v]) => `${k}=${v}`).join(' ') || 'none'}`);
        const tt = dump.cgperf.translate_top || [];
        if (tt.length) {
            console.log(`    slowest translations: ${tt.slice(0, 6).map((t) => `${t.label.slice(0, 40)} ${t.translate_ms.toFixed(0)}ms`).join(' | ')}`);
        }
    }
    if (dump.write_by_label && dump.write_by_label.length) {
        const frames = dump.frames_seen || 1;
        console.log(`    queue writes by label (per frame, over ${frames} frames): calls · KB · max KB`);
        for (const [k, calls, bytes, max] of dump.write_by_label.slice(0, 12)) {
            console.log(`      ${(calls / frames).toFixed(1).padStart(7)} · ${(bytes / frames / 1024).toFixed(0).padStart(8)} · ${(max / 1024).toFixed(0).padStart(7)}  ${k}`);
        }
    }
    await context.close();
    server.close();
    const rec = {
        tag: TAG,
        label: exp.label,
        dir: exp.dir,
        scene,
        query: QUERY,
        throttle: THROTTLE,
        run: runIdx,
        started: new Date(t0).toISOString(),
        wall_s: (Date.now() - t0) / 1000,
        verdict: verdict || 'TIMEOUT',
        lines,
        perf_lines: raw.slice(-20),
        errors: errors.slice(0, 50),
        console_tail: tail,
        grepped,
        profile_top: profileSummary ? profileSummary.top : null,
        ...dump,
    };
    const suffix = THROTTLE > 1 ? `.t${THROTTLE}` : '';
    const file = join(OUT_DIR, `${exp.label}.${scene}${suffix}${RUNS > 1 ? `.r${runIdx}` : ''}.json`);
    writeFileSync(file, JSON.stringify(rec, null, 1));
    return rec;
}

function demangle(names) {
    try {
        const out = execFileSync('c++filt', { input: names.join('\n') + '\n' }).toString().split('\n');
        return names.map((n, i) => out[i] || n);
    } catch {
        return names;
    }
}

/**
 * Self-time table from a CDP profile. Steady-state only: samples in the first third of the
 * recording (boot, wasm compile, shader translation) are dropped so the table describes frames,
 * not loading. Wasm frames arrive as `functionName` = mangled symbol when the template kept its
 * name section, or `wasm-function[N]` when it did not.
 */
function summarizeProfile(profile) {
    const nodes = new Map(profile.nodes.map((n) => [n.id, n]));
    const total = profile.samples.length;
    const start = Math.floor(total / 3);
    const self = new Map();
    for (let i = start; i < total; i++) {
        const n = nodes.get(profile.samples[i]);
        if (!n) {
            continue;
        }
        const cf = n.callFrame;
        const key = cf.functionName || `(anon ${cf.url.split('/').pop()}:${cf.lineNumber})`;
        self.set(key, (self.get(key) || 0) + 1);
    }
    const used = total - start;
    const rows = [...self.entries()].sort((a, b) => b[1] - a[1]).slice(0, 40);
    const names = demangle(rows.map((r) => r[0]));
    let wasm = 0;
    let js = 0;
    for (const [k, v] of self) {
        if (/^_Z|^wasm-function|^dyn|^invoke_/.test(k)) {
            wasm += v;
        } else {
            js += v;
        }
    }
    const lines = [`    steady-state samples: ${used} (wasm ${(100 * wasm / used).toFixed(0)}%, js/native ${(100 * js / used).toFixed(0)}%)`];
    const top = rows.map((r, i) => ({ name: names[i].slice(0, 110), pct: 100 * r[1] / used }));
    for (const t of top.slice(0, 25)) {
        lines.push(`    ${t.pct.toFixed(1).padStart(5)}%  ${t.name}`);
    }
    return { top, text: lines.join('\n') };
}

function median(nums) {
    const s = nums.filter((x) => typeof x === 'number').sort((a, b) => a - b);
    return s.length ? s[Math.floor(s.length / 2)] : null;
}

function fmt(v, d = 2) {
    return v === null || v === undefined ? 'na' : Number(v).toFixed(d);
}

function table(records) {
    // rows: scene/phase; cols per label: fps | frame p50/p95 | busy p50/p95 | warm_max | hitch
    const labels = [...new Set(records.map((r) => r.label))];
    const scenes = [...new Set(records.map((r) => r.scene))];
    const out = [];
    for (const scene of scenes) {
        const phases = [];
        for (const r of records.filter((r) => r.scene === scene)) {
            for (const l of r.lines.filter((l) => l.tag === scene)) {
                if (!phases.includes(l.fields.phase)) {
                    phases.push(l.fields.phase);
                }
            }
        }
        out.push(`\n### ${scene}${THROTTLE > 1 ? ` (cpu ×${THROTTLE} throttle)` : ''}`);
        out.push(`| phase | ${labels.map((l) => `${l}: fps · frame p50/p95 · busy p50/p95 · warm_max · hitch`).join(' | ')} |`);
        out.push(`|---|${labels.map(() => '---').join('|')}|`);
        for (const phase of phases) {
            const cells = labels.map((label) => {
                const runs = records.filter((r) => r.scene === scene && r.label === label);
                const rows = runs.flatMap((r) => r.lines.filter((l) => l.tag === scene && l.fields.phase === phase).map((l) => l.fields));
                if (!rows.length) {
                    return 'no data';
                }
                const m = (k) => median(rows.map((f) => f[k]));
                return `${fmt(m('fps'), 1)} · ${fmt(m('frame_p50'))}/${fmt(m('frame_p95'))} · ${fmt(m('busy_p50'))}/${fmt(m('busy_p95'))} · ${fmt(m('warm_max_ms'), 0)} · ${fmt(m('hitch50'), 0)}`;
            });
            out.push(`| ${phase} | ${cells.join(' | ')} |`);
        }
        const loads = labels.map((label) => {
            const runs = records.filter((r) => r.scene === scene && r.label === label);
            const rows = runs.flatMap((r) => r.lines.filter((l) => l.tag === 'load').map((l) => l.fields));
            return rows.length ? `${fmt(median(rows.map((f) => f.first_frame_ms)), 0)} ms to first frame, ${fmt(median(rows.map((f) => f.compiles)), 0)} compiles` : 'na';
        });
        out.push(`| _load_ | ${loads.join(' | ')} |`);
    }
    return out.join('\n');
}

async function main() {
    const pw = await loadPlaywright();
    console.log(`tag=${TAG} throttle=${THROTTLE} runs=${RUNS} scenes=${SCENES.join(',')} query='${QUERY}'`);
    console.log(`exports: ${EXPORTS.map((e) => `${e.label}=${e.dir}`).join('  ')}`);
    let browser = FRESH ? null : await launch(pw);
    const records = [];
    for (const scene of SCENES) {
        for (const exp of EXPORTS) {
            for (let run = 0; run < RUNS; run++) {
                if (FRESH) {
                    browser = await launch(pw);
                }
                const suffixE = THROTTLE > 1 ? `.t${THROTTLE}` : '';
                const existing = join(OUT_DIR, `${exp.label}.${scene}${suffixE}${RUNS > 1 ? `.r${run}` : ''}.json`);
                if (SKIP_EXISTING && existsSync(existing)) {
                    console.log(`\n▶ ${exp.label} / ${scene}: skipped (exists)`);
                    records.push(JSON.parse(readFileSync(existing, 'utf8')));
                    continue;
                }
                console.log(`\n▶ ${exp.label} / ${scene} (run ${run + 1}/${RUNS})`);
                const rec = await runOne(browser, pw, exp, scene, run);
                console.log(`  ${rec.verdict}  (${rec.wall_s.toFixed(1)} s${rec.errors.length ? `, ${rec.errors.length} console errors` : ''})`);
                if (rec.errors.length) {
                    for (const e of rec.errors.slice(0, 5)) {
                        console.log(`    ! ${e.slice(0, 200)}`);
                    }
                }
                records.push(rec);
                if (FRESH) {
                    await browser.close();
                }
            }
        }
    }
    if (!FRESH) {
        await browser.close();
    }
    const md = table(records);
    console.log(md);
    writeFileSync(join(OUT_DIR, 'SUMMARY.md'), `# ${TAG}\n\nquery: \`${QUERY}\`  throttle: ${THROTTLE}  runs: ${RUNS}\n${md}\n`);
    console.log(`\nresults: ${OUT_DIR}`);
}

main().catch((e) => {
    console.error(e);
    process.exit(1);
});
