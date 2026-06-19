# cl-godot-web

A **minimal Godot 4.7 web game** wired up for deployment to **Cloudflare Pages**,
built specifically to surface and test Godot's web-export *size* issues.

The game itself is deliberately trivial (a bouncing icon + an FPS readout) so
that essentially **all** of the payload is the Godot engine — which is exactly
what we want to measure.

## Measured sizes (Godot 4.7-stable, release, GL Compatibility)

| File          | Raw    | gzip   | Notes                                  |
| ------------- | ------ | ------ | -------------------------------------- |
| `index.wasm`  | 38 MB  | 9.7 MB | The engine. This is the whole problem. |
| `index.js`    | 308 KB | 73 KB  | Loader / glue code.                    |
| `index.pck`   | 8 KB   | ~4 KB  | Our actual game data.                  |
| everything else | <40 KB | —    | html, icons, audio worklets.           |

**Takeaways for the size investigation:**

1. **The 25 MiB wall.** Cloudflare Pages (and Workers static assets) reject any
   single file larger than **25 MiB**. The raw 38 MB `index.wasm` *cannot be
   uploaded as-is*. This is the first hard blocker you hit.
2. **Compression fixes the upload, not the download cost.** Gzipped the wasm is
   ~9.7 MB; brotli would be ~7–8 MB. That's the real number a player downloads.
3. **The game is ~free; the engine is everything.** `index.pck` is 8 KB. Shrinking
   the payload means shrinking the *engine*, not the game.

## How this repo solves the 25 MiB limit

`scripts/build-web.sh` exports the project and then **pre-gzips** the heavy
assets (`index.wasm`, `index.pck`, `index.js`, audio worklets), keeping their
original filenames. The largest file Cloudflare stores drops to **9.7 MB** —
comfortably under the limit — while the browser still receives a valid 38 MB
wasm module.

The catch with Cloudflare **Pages** specifically: it **strips `Content-Encoding`
from the `_headers` file** *and* auto-Brotli-compresses responses. A pre-gzipped
file served via `_headers` therefore ends up Brotli-wrapped around gzip bytes —
double-encoded and unreadable (`Uncaught SyntaxError: Invalid or unexpected
token`).

The fix is a small **advanced-mode worker** (`cloudflare/_worker.js`, copied into
`dist/` at build time). Because it serves every request, it can:

- declare `Content-Encoding: gzip` on the pre-compressed assets, so the edge
  doesn't re-compress and the browser inflates them correctly; and
- set the cross-origin isolation headers
  (`Cross-Origin-Opener-Policy: same-origin` +
  `Cross-Origin-Embedder-Policy: require-corp`) that Godot's **threaded** build
  needs for `SharedArrayBuffer`. (In advanced mode the `_headers` file is
  ignored, so these live in the worker.)

## Layout

```
game/                 Godot project (project.godot, Main.tscn, Main.gd, icon.svg)
  export_presets.cfg  Web export preset
cloudflare/_worker.js Advanced-mode worker copied into dist/ at build time
scripts/
  install-godot.sh    Fetch Godot 4.7 + Web export templates
  build-web.sh        Export -> gzip -> dist/  (Cloudflare-ready)
dist/                 Committed, deploy-ready output (gzipped assets + _headers)
wrangler.toml         Cloudflare Pages project config
.github/workflows/deploy.yml   CI: install, build, deploy on push to main
```

## Build locally

```bash
# One-time: install the engine + Web export templates (~1.3 GB download)
bash scripts/install-godot.sh

# Export and produce the Cloudflare-ready dist/
bash scripts/build-web.sh
```

## Deploy to Cloudflare

**Option A — Wrangler CLI:**

```bash
npx wrangler pages deploy dist --project-name=cl-godot-web
```

**Option B — CI (GitHub Actions):** add repo secrets `CLOUDFLARE_API_TOKEN`
and `CLOUDFLARE_ACCOUNT_ID`; pushes to `main` build and deploy automatically.

> Note: opening `dist/index.html` directly off disk (`file://`) will *not* work —
> Godot needs the cross-origin-isolation headers, so it must be served over HTTP
> by Cloudflare (or a local server that sets COOP/COEP).

## Further size reductions to test

- **Brotli instead of gzip** — ~20% smaller wasm; swap `gzip` for `brotli` in
  `build-web.sh` and change `Content-Encoding` to `br` in `cloudflare/_worker.js`.
- **`nothreads` template** — set `variant/thread_support=false` in
  `export_presets.cfg`. Smaller, single-threaded, and drops the COOP/COEP
  requirement entirely (no `SharedArrayBuffer`).
- **Custom engine build** — compile Godot's web export template with unused
  modules disabled (`module_*_enabled=no`) for the biggest wins. This is the only
  way to meaningfully shrink the 38 MB figure.
