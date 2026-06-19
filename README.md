# cl-godot-web

A **minimal Godot 4.7 web game** wired up for deployment to **Cloudflare Pages**,
built specifically to surface and test Godot's web-export *size* issues.

The game itself is **Dodge the Creeps** — Godot's official "Your first 2D game"
tutorial (sprites, a font, a music loop and a sound effect) — so that the
payload now includes *real game content* on top of the engine. That lets us
measure how actual assets move the numbers, not just the engine baseline.

## Measured sizes (Godot 4.7-stable, release, GL Compatibility)

| File          | Raw    | gzip   | Notes                                  |
| ------------- | ------ | ------ | -------------------------------------- |
| `index.wasm`  | 38 MB  | 9.7 MB | The engine. This is the whole problem. |
| `index.js`    | 308 KB | 73 KB  | Loader / glue code.                    |
| `index.pck`   | 1.6 MB | ~1.5 MB | Game data: scenes, scripts, sprites, font, and audio. The 1.4 MB Ogg music loop dominates. |
| everything else | <40 KB | —    | html, icons, audio worklets.           |

> The earlier minimal scene (a bouncing icon) produced an **8 KB** `index.pck`.
> Adding the tutorial's content pushed it to **~1.6 MB** — and it's almost all
> the bundled audio, not code or sprites. Even so, the `pck` stays far under
> Cloudflare's 25 MiB per-file limit; `index.wasm` remains the only file that
> needs the pre-gzip + worker treatment. So real game content is cheap relative
> to the engine: the engine is still ~95% of the download.

### With the custom slim engine template

`scripts/build-template.sh` recompiles the engine size-optimized and 2D-only
(see below). The shipped `custom_template/web_release.zip` is built that way, so
`dist/` uses it by default:

| `index.wasm` | Raw   | gzip   |
| ------------ | ----- | ------ |
| Stock 4.7    | 38 MB | 9.7 MB |
| Custom slim  | 27 MB | 7.1 MB |

≈ **29% smaller** on both disk and download. Still over the 25 MiB raw limit, so
the worker is still needed — but the download players feel drops to ~7 MB.

**Takeaways for the size investigation:**

1. **The 25 MiB wall.** Cloudflare Pages (and Workers static assets) reject any
   single file larger than **25 MiB**. The raw 38 MB `index.wasm` *cannot be
   uploaded as-is*. This is the first hard blocker you hit.
2. **Compression fixes the upload, not the download cost.** Gzipped the wasm is
   ~9.7 MB; brotli would be ~7–8 MB. That's the real number a player downloads.
3. **The game is ~free; the engine is everything.** `index.pck` is 8 KB. Shrinking
   the payload means shrinking the *engine*, not the game.

## How this repo solves the 25 MiB limit

Only `index.wasm` (~38 MB) exceeds Cloudflare Pages' 25 MiB per-file limit, so
`scripts/build-web.sh` **pre-gzips just that one file** (~10 MB stored, filename
preserved). Every other file stays raw.

The tricky part is serving the gzipped wasm. On Cloudflare you **cannot**:

- set `Content-Encoding` in the `_headers` file — Pages strips it; or
- set `Content-Encoding` in a Worker either — Cloudflare strips it from Worker
  responses and then Brotli-compresses the body itself. A relabeled gzip file
  ends up Brotli-wrapped around gzip bytes — double-encoded and unreadable
  (`Uncaught SyntaxError: Invalid or unexpected token`).

So the fix (`cloudflare/_worker.js`, an advanced-mode worker copied into `dist/`)
**decompresses the wasm at the edge** and hands Cloudflare plain bytes;
Cloudflare then applies its own correct compression on the way out. Everything
else is a normal raw asset that Cloudflare compresses natively.

The worker also sets the cross-origin isolation headers
(`Cross-Origin-Opener-Policy: same-origin` +
`Cross-Origin-Embedder-Policy: require-corp`) that Godot's **threaded** build
needs for `SharedArrayBuffer` — in advanced mode the `_headers` file is ignored,
so these live in the worker.

> If the custom slimmed-down engine template (see `scripts/build-template.sh`)
> brings the wasm under 25 MB, none of this is needed: store every file raw, set
> COOP/COEP in a plain `_headers` file, and let Cloudflare do all compression.

## Layout

```
game/                 Godot project — Dodge the Creeps (main.tscn, player/mob/hud
                      scenes + scripts, art/, fonts/, icon.webp)
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

## The custom engine template

`scripts/build-template.sh` rebuilds Godot's Web export template (Emscripten
4.0.11, matching Godot 4.7's CI) with:

- `optimize=size lto=full production=yes` — `-Os` + whole-program dead-code elim
- `disable_3d=yes` — drops the entire 3D stack (this is a 2D game)
- `deprecated=no` — drops deprecated APIs
- `module_text_server_adv_enabled=no module_text_server_fb_enabled=yes` — swaps
  the ICU-heavy advanced text server for the fallback (no complex-script/BiDi
  shaping, but several MB lighter)

Output: `custom_template/web_release.zip`, which `game/export_presets.cfg` points
at via `custom_template/release`. It's a ~45 min compile.

### Further reductions to try

- **Build profile** — have the editor scan the project and disable every unused
  class (`build_profile=res://x.build`). Biggest remaining win for a minimal game.
- **`nothreads` template** — `threads=no` (and `variant/thread_support=false` in
  the preset). Drops the COOP/COEP requirement entirely, at the cost of threads.
- **`wasm-opt -Oz`** (Binaryen) as a post-step for a final few percent.
