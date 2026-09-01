# Multi-Browser Screenshot Comparison

Automated visual regression testing for the WebGPU rendering backend. Captures screenshots of deterministic WebGPU scenes across Chrome and Firefox, then compares against baselines.

## Test Scenes

| Scene | What it exercises |
|-------|------------------|
| **triangle** | Vertex colors, basic rasterization, clear color |
| **textured_quad** | Texture upload, sampler creation, UV mapping |
| **instanced** | Instance buffers, vertex attribute layouts, 64 draw instances |
| **compute_pattern** | Compute→render pipeline, storage textures, Mandelbrot fractal |

## Running

### First run (create baselines)
```bash
npm install playwright
npx playwright install chromium firefox
node screenshot_tests.mjs --update-baselines
```

### Subsequent runs (compare against baselines)
```bash
node screenshot_tests.mjs
```

### Options
```
--update-baselines    Save current screenshots as new baselines
--threshold 0.05      Set pixel difference threshold (0-1, default 0.01)
```

## Output

```
screenshots/
├── baselines/          Reference images (committed to git)
│   ├── chromium_triangle.png
│   ├── chromium_textured_quad.png
│   ├── firefox_triangle.png
│   └── ...
├── current/            Latest captures (gitignored)
├── diffs/              Visual diff images on failure (gitignored)
└── report.json         Machine-readable results
```

## What it catches

- **Regression within a browser** — shader compilation changes, resource binding errors, format promotion bugs
- **Cross-browser divergence** — implementation differences between Chrome's Dawn and Firefox's wgpu backends
- **Driver updates** — GPU driver changes that alter rasterization behavior

## Comparison approach

- **Same-browser regression**: Exact byte comparison with configurable threshold (default 1%)
- **Cross-browser comparison**: Looser threshold (5x) since implementations legitimately differ in edge-case rasterization

## CI integration

Run the Playwright runner under an X server on Linux:

```bash
xvfb-run --auto-servernum node screenshot_tests.mjs --update-baselines
```

CI requires headed Chromium and Firefox because their Linux headless WebGPU paths do not expose the
same usable adapters. It exits nonzero unless all four scenes produce screenshots in both browsers
(8/8), and always writes `screenshots/report.json` after capture so a failed run is diagnosable.
