#!/usr/bin/env bash
#
# Export the Godot project to a Web build and prepare a Cloudflare-ready
# deploy directory in dist/.
#
# Why the post-processing step exists:
#   Godot's release wasm is ~38 MB uncompressed. Cloudflare Pages enforces a
#   25 MiB-per-file limit, so the raw wasm cannot be uploaded as-is. We gzip the
#   large assets ahead of time and serve them with an explicit
#   `Content-Encoding: gzip` header (see dist/_headers). The stored, gzipped
#   wasm is ~10 MB, comfortably under the limit, and the browser's fetch()
#   transparently decompresses it.
#
# Requirements: godot (4.7) on PATH with the matching Web export templates
# installed. See scripts/install-godot.sh.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GAME_DIR="$ROOT/game"
RAW_DIR="$ROOT/build"
DIST_DIR="$ROOT/dist"
GODOT_BIN="${GODOT_BIN:-godot}"

echo "==> Exporting Web build with $GODOT_BIN"
rm -rf "$RAW_DIR" "$DIST_DIR"
mkdir -p "$RAW_DIR" "$DIST_DIR"

# Import assets first so the headless export has a clean filesystem cache.
"$GODOT_BIN" --headless --path "$GAME_DIR" --import >/dev/null 2>&1 || true
"$GODOT_BIN" --headless --path "$GAME_DIR" --export-release "Web"

echo "==> Raw export sizes"
du -h "$RAW_DIR"/* | sort -h

echo "==> Building Cloudflare deploy dir (dist/)"
cp -r "$RAW_DIR"/. "$DIST_DIR"/

# Pre-compress the heavy assets. Filenames are preserved; the bytes are gzip.
# dist/_headers declares Content-Encoding so Cloudflare serves them verbatim.
for f in index.wasm index.pck index.js index.audio.worklet.js index.audio.position.worklet.js; do
	if [ -f "$DIST_DIR/$f" ]; then
		gzip -9 -k -f "$DIST_DIR/$f"
		mv "$DIST_DIR/$f.gz" "$DIST_DIR/$f"
	fi
done

cp "$ROOT/cloudflare/_headers" "$DIST_DIR/_headers"

echo "==> dist/ sizes (what Cloudflare stores)"
du -h "$DIST_DIR"/* | sort -h
echo
echo "==> Largest stored file:"
du -h "$DIST_DIR"/* | sort -h | tail -1
echo "    (Cloudflare Pages per-file limit is 25 MiB)"
echo "Done. Deploy with: npx wrangler pages deploy dist"
