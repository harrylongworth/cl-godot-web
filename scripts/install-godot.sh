#!/usr/bin/env bash
#
# Install the Godot 4.7 headless editor + Web export templates.
# Used by CI and for local reproduction of the web build.
#
set -euo pipefail

GODOT_VERSION="${GODOT_VERSION:-4.7-stable}"
GODOT_DOTVER="${GODOT_VERSION%-stable}.stable"   # e.g. 4.7.stable
BASE="https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}"
BIN_DIR="${BIN_DIR:-/usr/local/bin}"
TPL_DIR="$HOME/.local/share/godot/export_templates/${GODOT_DOTVER}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "==> Downloading Godot ${GODOT_VERSION} editor"
curl -sL --retry 4 -o "$tmp/godot.zip" \
	"${BASE}/Godot_v${GODOT_VERSION}_linux.x86_64.zip"
unzip -o -q "$tmp/godot.zip" -d "$tmp"
install -m 0755 "$tmp/Godot_v${GODOT_VERSION}_linux.x86_64" "$BIN_DIR/godot"
godot --headless --version

echo "==> Downloading export templates (~1.3 GB)"
curl -sL --retry 4 -o "$tmp/templates.tpz" \
	"${BASE}/Godot_v${GODOT_VERSION}_export_templates.tpz"

echo "==> Installing Web export templates to ${TPL_DIR}"
mkdir -p "$TPL_DIR"
unzip -o -q "$tmp/templates.tpz" "templates/web*" -d "$tmp/tpl"
cp "$tmp"/tpl/templates/web*.zip "$TPL_DIR/"
echo "$GODOT_DOTVER" > "$TPL_DIR/version.txt"
echo "==> Done."
