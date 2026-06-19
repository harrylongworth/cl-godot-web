# CLAUDE.md — Godot 4 → Web → Cloudflare playbook

Hard-won notes for deploying Godot web exports to Cloudflare Pages. Read this
before setting up another Godot web app — it will save hours.

## TL;DR of what actually works

1. Export the game (`scripts/build-web.sh`).
2. **gzip only `index.wasm`** (it's the only file over Cloudflare's limit).
3. Ship an advanced-mode **`_worker.js`** that **decompresses the wasm at the
   edge** and sets the cross-origin isolation headers.
4. Deploy `dist/` (Pages build output directory = `dist`, no build command).
5. **Purge the Cloudflare cache** after any change to encoding/headers.

## The four traps (in the order they bite you)

### 1. Cloudflare Pages 25 MiB per-file limit
Godot's release `index.wasm` is ~38 MB. Pages (and Workers static assets)
**reject any single file over 25 MiB**, so the raw wasm cannot be uploaded.
→ Store the wasm **pre-gzipped** (`gzip -9`, ~10 MB). Leave every other file raw;
nothing else is close to the limit.

### 2. Cross-origin isolation is required for threaded builds
Godot's default (threaded) web export uses `SharedArrayBuffer`, which only works
on a **cross-origin-isolated** page. You must send:
```
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
```
Without them the game fails to boot. (A `nothreads` build avoids this entirely.)
- These headers **do** work from a `_headers` file on Pages.
- `file://` will never work — must be served over HTTP with these headers.

### 3. You cannot relabel pre-compressed content on Cloudflare
This is the big one. To serve a pre-gzipped file you'd want to set
`Content-Encoding: gzip`. **Cloudflare strips `Content-Encoding`:**
- from the `_headers` file (silently ignored), **and**
- from **Worker responses** too — then it re-compresses the body itself.

So a pre-gzipped file labeled `gzip` becomes **Brotli-wrapped-around-gzip** —
double-encoded. Symptom in the browser:
```
index.js:1 Uncaught SyntaxError: Invalid or unexpected token
(index):NN Uncaught ReferenceError: Engine is not defined
```
(`Engine` is undefined only because `index.js` failed to parse.)

→ The fix that works: an **advanced-mode `_worker.js`** (a `_worker.js` file at
the root of the deploy dir) that **decompresses** the gzipped wasm with
`DecompressionStream("gzip")` and returns **plain bytes**. Cloudflare then
applies its own correct compression on egress. Don't try to relabel — decompress.

Note: in advanced mode the `_headers` file is **ignored**, so COOP/COEP must be
set in the worker too.

### 4. Aggressive caching poisons deploys
Setting `Cache-Control: immutable, max-age=31536000` on a file whose URL doesn't
change (`/index.js`) means Cloudflare's edge cache keeps serving the **old**
bytes across new deployments. We shipped a broken `index.js` once with immutable
caching and the fix wouldn't take effect until the cache was purged.
- After changing anything about encoding/headers/worker: **Caching → Purge
  Everything** (or purge the specific URL), then hard-refresh.
- Only put `immutable` on content that truly never changes at that URL (the
  wasm here). Diagnose with `cf-cache-status: HIT` + a non-zero `age`.

## Diagnostics that cut through the confusion

```bash
# What the browser actually receives (curl --compressed mimics Accept-Encoding):
curl -s --compressed -D - https://SITE/index.js  -o /tmp/b | grep -i content-encoding
head -c 8 /tmp/b | od -A n -t x1     # JS should be ASCII "var Godot..."; wasm -> 00 61 73 6d
curl -s --compressed https://SITE/index.wasm | head -c 4 | od -A n -t x1   # want 00 61 73 6d
curl -s --compressed https://SITE/index.pck  | head -c 4   # want "GDPC"

# Is it a stale cache vs a real bug? Add a cache-buster:
curl -s --compressed "https://SITE/index.js?cb=$RANDOM" -D - -o /tmp/b | grep -i cf-cache-status
# MISS + valid bytes  => deploy is fine, you just need to purge cache.
```

Magic bytes: wasm = `00 61 73 6d` (`\0asm`), gzip = `1f 8b`, pck = `47 44 50 43`
(`GDPC`). If `--compressed` output still starts with `1f 8b`, it's double-encoded.

## Reducing wasm size (the only real fix for the 38 MB)

Compression only shrinks the download; the binary is shrunk by rebuilding the
engine. See `scripts/build-template.sh`. Use the Emscripten version Godot's own
CI uses (4.7 → **4.0.11**; check `.github/workflows/web_builds.yml` in the Godot
source). Effective flags:
```
scons platform=web target=template_release production=yes \
  optimize=size lto=full \
  disable_3d=yes deprecated=no \
  module_text_server_adv_enabled=no module_text_server_fb_enabled=yes
```
- `optimize=size` (`-Os`) + `lto=full` — the core size win.
- `disable_3d=yes` — big for a 2D game.
- advanced→fallback **text server** drops ICU (several MB). Lose complex-script
  / BiDi shaping; fine for Latin-only UIs.
- Biggest remaining lever: an editor **build profile** that disables unused
  classes (`build_profile=res://x.build`).

Measured here: **38 MB → 27 MB raw, 9.7 MB → 7.1 MB gzipped (~29%).** Still over
25 MiB raw, so the worker stays. If a future build drops the wasm **under
25 MiB**, delete the worker entirely: store every file raw, set COOP/COEP in a
plain `_headers`, and let Cloudflare do all compression. That's the clean
end-state to aim for.

## Cloudflare Pages settings (GitHub integration)

- **Project type:** Direct upload is simplest, but Git integration works if you
  commit `dist/`.
- **Build command:** *(empty)* — the repo ships a prebuilt `dist/`.
- **Build output directory:** `dist` — if this is wrong, none of the above takes
  effect (the worker/headers never reach the edge).
- **Production branch:** `main`.
- Do **not** use the Git "framework preset" build to compile Godot — the export
  templates are ~1.3 GB; build in CI (see `.github/workflows/deploy.yml`) with
  caching instead.

## Repo map

```
game/                  Godot project + export_presets.cfg (Web preset)
cloudflare/_worker.js  Advanced-mode worker (decompress wasm + isolation headers)
custom_template/       Prebuilt slim Web export template
scripts/
  install-godot.sh     Editor + stock Web export templates
  build-web.sh         Export -> gzip wasm -> dist/
  build-template.sh    Compile the size-optimized custom template (~45 min)
dist/                  Committed, deploy-ready output
```
