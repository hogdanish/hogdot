/**
 * Overrides-mode A/B gate for tint_convert_cli (shader baker step 2).
 *
 * Runs every fixture through the CLI twice — default (freeze spec constants)
 * and --overrides (keep them as WGSL overrides) — and gates on:
 *   1. No fixture that converts in default mode fails in overrides mode.
 *   2. Per-stage binding-count growth is reported (override WGSL cannot be
 *      dead-code-eliminated, so binding counts can only grow; growth past a
 *      WebGPU per-stage limit means that shader must bake SPIR-V-only).
 *
 * Usage: node overrides_ab.mjs
 */

import { readdirSync, existsSync } from 'fs';
import { join, basename, dirname } from 'path';
import { fileURLToPath } from 'url';
import { execFileSync } from 'child_process';

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = join(__dirname, '..', '..');
const FIXTURES_DIR = join(__dirname, 'fixtures');
const CLI = join(REPO_ROOT, 'bin', 'tint_convert_cli');

if (!existsSync(CLI)) {
    console.error(`FAIL: ${CLI} not found — run drivers/webgpu/tint_cli/build.sh first.`);
    process.exit(1);
}

function convert(spvPath, overrides) {
    const args = overrides ? ['--overrides', spvPath] : [spvPath];
    try {
        return { ok: true, wgsl: execFileSync(CLI, args, { encoding: 'utf-8', timeout: 30000 }) };
    } catch (e) {
        return { ok: false, error: (e.stderr || e.message || String(e)).slice(0, 200) };
    }
}

function bindingCount(wgsl) {
    // Tint prints integer attribute args with a `u` suffix: @group(0u) @binding(1u).
    return new Set([...wgsl.matchAll(/@group\((\d+)u?\)\s*@binding\((\d+)u?\)/g)].map(m => `${m[1]}:${m[2]}`)).size;
}

function overrideCount(wgsl) {
    return [...wgsl.matchAll(/@id\(\d+\)\s*override/g)].length;
}

const fixtures = readdirSync(FIXTURES_DIR).filter(f => f.endsWith('.spv')).sort();
let gateFailures = 0;
let bindingGrowth = 0;
const rows = [];

for (const f of fixtures) {
    const p = join(FIXTURES_DIR, f);
    const def = convert(p, false);
    const ovr = convert(p, true);
    const name = basename(f, '.spv');

    if (def.ok && !ovr.ok) {
        gateFailures++;
        rows.push(`  [GATE-FAIL] ${name}: default OK, overrides FAILED: ${ovr.error}`);
        continue;
    }
    if (!def.ok) {
        rows.push(`  [SKIP] ${name}: fails in default mode too (${def.error.slice(0, 80)})`);
        continue;
    }
    const bDef = bindingCount(def.wgsl);
    const bOvr = bindingCount(ovr.wgsl);
    const nOvr = overrideCount(ovr.wgsl);
    const delta = bOvr - bDef;
    if (delta > 0) {
        bindingGrowth++;
    }
    rows.push(`  [OK] ${name}: bindings ${bDef} -> ${bOvr} (${delta >= 0 ? '+' : ''}${delta}), overrides emitted: ${nOvr}`);
}

console.log(`Overrides A/B over ${fixtures.length} fixtures:\n`);
console.log(rows.join('\n'));
console.log(`\nGate: ${gateFailures === 0 ? 'PASS' : 'FAIL'} (${gateFailures} overrides-only failures, ${bindingGrowth} fixtures with binding growth)`);
process.exit(gateFailures === 0 ? 0 : 1);
