# Handover: migrating Godot web games from Cloudflare R2 → Pages

**Audience:** whoever picks up `god-dcc` (and any future Godot web game) next.
**Reference implementation:** `cl-godot-web` — a working Godot web build on
Cloudflare Pages. Copy its `scripts/`, `cloudflare/_worker.js`, and `CLAUDE.md`
as the starting point. Read `CLAUDE.md` first; it explains every trap.

**Status:** `god-dungeonlight` is **DONE** (2026-06-19) — see "What actually
happened on god-dungeonlight" below for the real-world deltas, especially the
**COOP/COEP correction**, before you touch `god-dcc`.

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
| **COOP/COEP isolation** (SharedArrayBuffer) | Set by a Worker in front of R2, or Transform Rules | `_headers` file, OR the `_worker.js` if in advanced mode — **but see the correction below** |
| **`Content-Type: application/wasm`** | Worker / R2 metadata | Pages sets by extension; worker re-asserts it |
| **Caching** | R2 + Cache Rules | `_headers` / worker `Cache-Control` |
| **Compression** | Worker or none | Cloudflare auto-compresses on egress |
| **Custom domain** | R2 custom domain / Worker route | Pages custom domain |

**Confirm whether each game is threaded** (default) or `nothreads` — this drives
the single biggest decision in the worker (see correction):
- Threaded → needs `Cross-Origin-Opener-Policy: same-origin` +
  `Cross-Origin-Embedder-Policy: require-corp`, or it won't boot.
- `nothreads` → no isolation headers needed (simpler). If a game is borderline
  on size/complexity, consider exporting `nothreads` to dodge the COOP/COEP
  requirement entirely.

How to check: `grep thread_support game/export_presets.cfg` (or wherever the
preset lives) and `grep GODOT_THREADS_ENABLED` in the exported `index.html`.

---

## 🚨 CORRECTION (learned on god-dungeonlight): the worker's COOP/COEP is conditional

The reference `cloudflare/_worker.js` in `cl-godot-web` calls an `isolate()`
helper that sets COOP/COEP on **every** response — because *that* build is
threaded. **Do not copy that part blindly.** Two independent reasons can require
you to strip it:

1. **`nothreads` builds don't need it.** No SharedArrayBuffer → isolation is
   pointless overhead.
2. **OAuth redirects break under `Cross-Origin-Opener-Policy: same-origin`.** If
   the game does any OAuth (e.g. Google sign-in via a browser redirect), COOP at
   the HTTP level blocks the cross-origin navigation and the login silently
   fails. This bit us conceptually on `god-dungeonlight` (nothreads **and**
   Google OAuth), so its worker sets **no** COOP/COEP at all and only does the
   wasm decompression.

**Decision table for the worker:**

| Build | OAuth? | Worker should set COOP/COEP? |
| --- | --- | --- |
| threaded | no | **Yes** (copy reference `isolate()` as-is) |
| threaded | yes | Conflict — prefer exporting `nothreads`, or scope COOP so it doesn't cover the OAuth document. Don't blanket-set it. |
| nothreads | either | **No** — decompress-only worker (see god-dungeonlight's) |

The decompression logic itself is identical in all cases; only the header block
changes.

---

## Migration steps (do per project)

1. **Copy the tooling from `cl-godot-web`:**
   - `scripts/build-web.sh` — export + gzip the wasm → `dist/`
   - `scripts/install-godot.sh` — get the editor + web templates
   - `cloudflare/_worker.js` — advanced-mode worker (decompress wasm + *maybe*
     isolation — see correction above)
   - optionally `scripts/build-template.sh` + `custom_template/` for the slim engine
   - `.github/workflows/deploy.yml` — CI build + deploy

2. **Determine threaded vs `nothreads` and OAuth-or-not** (above). Adjust the
   worker's header block accordingly **before** first deploy.

3. **Build:** `bash scripts/build-web.sh`. Confirm the largest file in `dist/`
   is the gzipped `index.wasm` and it's **under 25 MiB**. Add a CI guard so a
   future bloated build fails loudly instead of erroring at upload time:
   ```bash
   SIZE=$(du -m dist/web/index.wasm | cut -f1)
   test "$SIZE" -lt 25 || { echo "gzipped wasm over 25 MiB — use the slim template"; exit 1; }
   ```
   If it isn't under 25 MiB even after gzip (very large games can be), you *must*
   use the slim template (step 7).

4. **Do NOT patch `index.html`.** The old R2 approach rewrote
   `"executable":"index"` to an `assets.<domain>` URL. On Pages, leave
   `executable` as `"index"` so the loader fetches `/index.wasm` same-origin and
   the worker handles it. Patching it is a leftover from R2 — remove that step.

5. **Create the Pages project** (Direct upload or Git integration):
   - Build command: *(empty)* — `dist/` is prebuilt
   - **Build output directory: `dist`** ← if wrong, nothing works
   - Production branch: the project's default
   - **Advanced mode is automatic** when a `_worker.js` sits at the output root —
     no toggle. Note: in advanced mode the `_headers` file is *ignored*, so any
     headers you still want must live in `_worker.js`.

6. **Cut over the custom domain** in Pages, then **remove the R2 route/binding**
   once verified. Keep R2 around until the Pages deploy is confirmed good.

7. **(If still over 25 MiB, or to cut download size)** build the slim template:
   `bash scripts/build-template.sh` and point `custom_template/release` at
   `custom_template/web_release.zip`. On the test game this took 38 MB → 27 MB
   raw, 9.7 → 7.1 MB gzipped. Bigger wins via a **build profile** (editor-
   generated list of used classes) and `disable_3d=yes` for 2D games.

8. **Purge the Cloudflare cache** after the first good deploy, and again after any
   change to headers/encoding/worker. Use **Development Mode** while iterating.

---

## What actually happened on god-dungeonlight (reference deltas)

A pure-GDScript, **`nothreads`**, **Google-OAuth** Godot 4.5 game. Done
2026-06-19. Concrete numbers and choices that differed from the generic plan:

- **Sizes:** raw `index.wasm` 36,145,869 B (~35 MB) → `gzip -9` → **9.4 MB
  (10 MiB)**. Comfortably under 25 MiB; no slim template needed.
- **Worker:** decompress-only, **no COOP/COEP** (nothreads + OAuth — see
  correction). Decompresses via `DecompressionStream("gzip")`, re-asserts
  `Content-Type: application/wasm`, sets `Cache-Control: ... immutable`, and
  passes everything else straight through `env.ASSETS.fetch(request)`.
- **CI:** this repo already had R2 in its deploy workflows (it was uploading the
  wasm to the `dungeonlight-assets` bucket and `sed`-patching `index.html` to
  `assets.dungeonlight.com`). Migration = **delete** the "Upload wasm to R2" and
  "Patch index.html" steps, **add** a gzip-in-place + copy-`_worker.js` step with
  the `<25 MiB` guard. The deploy step (`pages deploy`) was unchanged.
- **Source of truth:** `cloudflare/_worker.js` is committed; CI copies it into
  `dist/web/_worker.js` at build time (the `dist/web/` binaries are gitignored).
- **Two environments, two Pages projects/branches** — names differ from generic
  docs, so check the actual workflow: `dungeonlight-game-dev` (dev) and
  `dungeonlight-game` (prod). Both deploy with `--branch=main`.
- **Result:** both `Deploy Dev` and `Deploy Production` went green on the *first*
  run of the new path. Live verification on both domains returned wasm magic
  `00 61 73 6d` (not gzip `1f 8b`) — worker confirmed working end-to-end.
- **Still pending (manual, dashboard):** remove the `assets.dungeonlight.com`
  custom domain and delete the `dev/`+`prod/` wasm objects from the R2 bucket.
  The bucket stays for future mods/DLC.

---

## Per-project notes

### god-dungeonlight — ✅ DONE (see deltas above)
- nothreads + Google OAuth → decompress-only worker, **no** COOP/COEP.
- 2D vs 3D: it's 3D, so `disable_3d` was not an option; gzip alone sufficed.

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
  - **Re-run the COOP/COEP decision** (correction above) for whatever auth and
    threading model god-dcc uses — don't assume it matches dungeonlight.

---

## Verification (same for both)

```bash
D=https://YOUR-DOMAIN
# wasm must decode to \0asm, not gzip magic:
curl -s --compressed "$D/index.wasm" | head -c 4 | od -A n -t x1   # want 00 61 73 6d
# js must be real source, not 1f 8b:
curl -s --compressed "$D/index.js" | head -c 16                    # want "var Godot..."
curl -s --compressed "$D/index.pck" | head -c 4                    # want GDPC
# isolation headers — ONLY if this build is threaded & uses COOP/COEP:
curl -s -I "$D/" | grep -i cross-origin                            # COOP + COEP
# stale cache check:
curl -s -I --compressed "$D/index.js" | grep -i cf-cache-status
```
Then load the page and confirm in DevTools: no `SharedArrayBuffer` error, no
`Uncaught SyntaxError`, and the game renders. **If the game uses OAuth, actually
complete a sign-in** after deploy — that's the failure mode a stray COOP header
hides until a real user hits it.

---

## Definition of done
- [ ] Worker's COOP/COEP block matches the build (threaded+no-OAuth → keep;
      nothreads or OAuth → strip) — decided *before* first deploy
- [ ] Pages project live on the custom domain, R2 route removed
- [ ] `curl` checks above all pass (wasm = `00 61 73 6d`)
- [ ] Game boots and runs in a fresh browser (cache cleared)
- [ ] If OAuth: a real sign-in completes after deploy
- [ ] CI (`deploy.yml`) builds + deploys on push to the project's branch, with a
      `<25 MiB` guard on the gzipped wasm
- [ ] Caching re-enabled for production; one purge done after final deploy
- [ ] R2 teardown: `assets.<domain>` custom domain + stale wasm objects removed
