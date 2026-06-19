#!/usr/bin/env bash
#
# Build a SIZE-OPTIMIZED custom Godot Web export template.
#
# The stock 4.7 release template is a 38 MB wasm. This rebuilds the engine with
# size flags and unused features stripped, producing a much smaller wasm. The
# resulting zip is written to custom_template/web_release.zip, which
# game/export_presets.cfg points at via `custom_template/release`.
#
# What we change vs. the stock template:
#   optimize=size lto=full production=yes   -> -Os + whole-program dead-code elim
#   disable_3d=yes                          -> drop the entire 3D stack (2D game)
#   deprecated=no                           -> drop deprecated APIs
#   module_text_server_adv -> _fb           -> drop ICU (~MBs); fallback shaper
#
# Requirements: git, python3, scons, and Emscripten (installed here via emsdk).
# Heavy: clones the Godot source and a full Emscripten toolchain, then compiles
# the engine (~30-45 min on 4 cores).
#
set -euo pipefail

GODOT_VERSION="${GODOT_VERSION:-4.7-stable}"
EM_VERSION="${EM_VERSION:-4.0.11}"   # matches Godot 4.7's own CI
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${WORK:-/tmp/godot-template-build}"
OUT="$ROOT/custom_template/web_release.zip"

mkdir -p "$WORK"

# --- Emscripten -----------------------------------------------------------
if [ ! -d "$WORK/emsdk" ]; then
	git clone --depth 1 https://github.com/emscripten-core/emsdk.git "$WORK/emsdk"
fi
"$WORK/emsdk/emsdk" install "$EM_VERSION"
"$WORK/emsdk/emsdk" activate "$EM_VERSION"
# shellcheck disable=SC1091
source "$WORK/emsdk/emsdk_env.sh"
emcc --version | head -1

# --- Godot source ---------------------------------------------------------
if [ ! -d "$WORK/godot-src" ]; then
	git clone --depth 1 --branch "$GODOT_VERSION" \
		https://github.com/godotengine/godot.git "$WORK/godot-src"
fi

# --- Build ----------------------------------------------------------------
cd "$WORK/godot-src"
scons platform=web target=template_release production=yes \
	optimize=size lto=full \
	disable_3d=yes deprecated=no \
	module_text_server_adv_enabled=no module_text_server_fb_enabled=yes \
	threads=yes \
	-j"$(nproc)"

# --- Collect --------------------------------------------------------------
mkdir -p "$ROOT/custom_template"
zip="$(ls -1 "$WORK"/godot-src/bin/godot.web.template_release.wasm32*.zip | head -1)"
cp "$zip" "$OUT"
echo "==> Custom template: $OUT"
unzip -l "$OUT"
