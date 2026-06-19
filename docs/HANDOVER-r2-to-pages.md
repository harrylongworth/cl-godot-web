# Handover: migrating Godot web games from Cloudflare R2 → Pages

**Audience:** whoever picks up `god-dcc` and `god-dungeonlight` next.
**Reference implementation:** this repo (`cl-godot-web`) — a working Godot 4.7
web build on Cloudflare Pages. Copy its `scripts/`, `cloudflare/_worker.js`, and
`CLAUDE.md` as the starting point. Read `CLAUDE.md` first; it explains every trap.

---

## ⚠️ Read this before you start

**R2 was hiding a problem that Pages will expose.** R2 is object storage with
**no per-file size limit**, so those games almost certainly serve the raw ~38 MB
`index.wasm` directly. **Cloudflare Pages rejects any file over 25 MiB.** The
moment you point Pages at the build, the deploy fails (or you get the broken,
double-compressed file). Everything below exists to get back under that limit.

So this is *not* a like-for-like move. Migrating to Pages means adopting:
1. **gzip the wasm** (only the wasm) so the stored file is ~7–10 MB, and
2. a **decompress worker** so the browser can actually read it, and/or
3. a **slim custom engine template** to shrink the wasm itself.

If you don't actually need to leave R2, R2 + a Worker for headers is genuinely a
*cleaner* host for big Godot wasm. The decision here is "off R2" — these notes
honour that, but flag the trade honestly.

---

## What carries over from R2 (don't lose these)

Whatever the R2 setup does today, find and port these, because Pages handles
them differently:

| Concern | On R2 (today) | On Pages (target) |
| --- | --- | --- |
| **COOP/COEP isolation** (SharedArrayBuffer) | Set by a Worker in front of R2, or Transform Rules | `_headers` file, OR the `_worker.js` if in advanced mode |
| **`Content-Type: application/wasm`** | Worker / R2 metadata | Pages sets by extension; worker re-asserts it |
| **Caching** | R2 + Cache Rules | `_headers` / worker `Cache-Control` |
| **Compression** | Worker or none | Cloudflare auto-compresses on egress |
| **Custom domain** | R2 custom domain / Worker route | Pages custom domain |

**Confirm whether each game is threaded** (default) or `nothreads`:
- Threaded → needs `Cross-Origin-Opener-Policy: same-origin` +
  `Cross-Origin-Embedder-Policy: require-corp`, or it won't boot.
- `nothreads` → no isolation headers needed (simpler). If a game is borderline
  on size/complexity, consider exporting `nothreads` to dodge the COOP/COEP
  requirement entirely.

---

## Migration steps (do per project)

1. **Copy the tooling from `cl-godot-web`:**
   - `scripts/build-web.sh` — export + gzip the wasm → `dist/`
   - `scripts/install-godot.sh` — get the editor + web templates
   - `cloudflare/_worker.js` — advanced-mode worker (decompress wasm + isolation)
   - optionally `scripts/build-template.sh` + `custom_template/` for the slim engine
   - `.github/workflows/deploy.yml` — CI build + deploy

2. **Point the export preset at the project's own `game/` dir** and set
   `export_path` to `../dist/index.html` (see this repo's `game/export_presets.cfg`).

3. **Build:** `bash scripts/build-web.sh`. Confirm the largest file in `dist/`
   is the gzipped `index.wasm` and it's **under 25 MiB**. If it isn't even after
   gzip (very large games can be), you *must* use the slim template (step 6).

4. **Create the Pages project** (Direct upload or Git integration):
   - Build command: *(empty)* — `dist/` is prebuilt
   - **Build output directory: `dist`** ← if wrong, nothing works
   - Production branch: the project's default (`dev` for both of these repos)

5. **Cut over the custom domain** in Pages, then **remove the R2 route/binding**
   once verified. Keep R2 around until the Pages deploy is confirmed good.

6. **(If still over 25 MiB, or to cut download size)** build the slim template:
   `bash scripts/build-template.sh` and point `custom_template/release` at
   `custom_template/web_release.zip`. On the test game this took 38 MB → 27 MB
   raw, 9.7 → 7.1 MB gzipped. Bigger wins are available via a **build profile**
   (editor-generated list of used classes) and `disable_3d=yes` for 2D games.

7. **Purge the Cloudflare cache** after the first good deploy, and again after any
   change to headers/encoding/worker. Use **Development Mode** while iterating so
   you don't have to purge every time (it auto-expires after 3 hours; re-enable
   caching for production).

---

## Per-project notes

### god-dungeonlight ("Rebuilding Dungeonlight in Godot", GDScript)
- Pure Godot/GDScript game → the standard path above applies directly.
- Check 2D vs 3D: if 2D, `disable_3d=yes` in the custom template is a big win.
- Likely wants threads (default) → keep COOP/COEP.

### god-dcc ("Godot + Google Antigravity", language shows TypeScript)
- The TypeScript suggests a **custom web shell / loader or wrapper** around the
  Godot export (not just the stock `index.html`). Before migrating:
  - Find where the wasm/pck are fetched. If a hand-written loader fetches
    `index.wasm`, the **decompress worker still works** (it operates at the HTTP
    layer, transparent to the loader) — but double-check the loader doesn't set
    its own `Accept-Encoding`/range logic that assumes raw bytes from R2.
  - If there's a TS build step (Vite/etc.), the Godot files are probably copied
    into a `public/`/`dist/` dir — make `build-web.sh`'s output land there, and
    set Pages' output directory to that build's output, not a bare `dist/`.
  - Range requests: some custom loaders stream the pck with HTTP Range. The
    decompress worker forces full responses for `index.wasm`; if the loader
    range-requests the **wasm** specifically, store the wasm raw + use the slim
    template to stay under 25 MiB instead of gzipping it.

---

## Verification (same for both)

```bash
D=https://YOUR-DOMAIN
# wasm must decode to \0asm, not gzip magic:
curl -s --compressed "$D/index.wasm" | head -c 4 | od -A n -t x1   # want 00 61 73 6d
# js must be real source, not 1f 8b:
curl -s --compressed "$D/index.js" | head -c 16                    # want "var Godot..."
curl -s --compressed "$D/index.pck" | head -c 4                    # want GDPC
# isolation headers present:
curl -s -I "$D/" | grep -i cross-origin                            # COOP + COEP
# stale cache check:
curl -s -I --compressed "$D/index.js" | grep -i cf-cache-status
```
Then load the page and confirm in DevTools: no `SharedArrayBuffer` error, no
`Uncaught SyntaxError`, and the game renders.

---

## Definition of done
- [ ] Pages project live on the custom domain, R2 route removed
- [ ] `curl` checks above all pass
- [ ] Game boots and runs in a fresh browser (cache cleared)
- [ ] CI (`deploy.yml`) builds + deploys on push to the project's branch
- [ ] Caching re-enabled for production; one purge done after final deploy
