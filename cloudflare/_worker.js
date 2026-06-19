// Cloudflare Pages advanced-mode worker for a Godot 4 Web build.
//
// Why this exists:
//   Godot's release wasm is ~38 MB, over Cloudflare's 25 MiB per-file limit, so
//   scripts/build-web.sh stores the heavy assets pre-gzipped (~10 MB). The catch:
//   Cloudflare Pages strips `Content-Encoding` from the `_headers` file AND
//   auto-Brotli-compresses responses, so a pre-gzipped file ends up
//   double-encoded and unreadable by the browser.
//
//   In advanced mode this worker serves every request, so we can declare the
//   correct `Content-Encoding: gzip` ourselves. The edge sees an already-encoded
//   response and won't re-compress it, and the browser transparently inflates it.
//
// Note: in advanced mode the `_headers` file is ignored, so the cross-origin
// isolation headers Godot's threaded build needs (SharedArrayBuffer) are set
// here too.

const GZIPPED = /\.(wasm|pck|js)$/;

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const asset = await env.ASSETS.fetch(request);

    const headers = new Headers(asset.headers);
    headers.set("Cross-Origin-Opener-Policy", "same-origin");
    headers.set("Cross-Origin-Embedder-Policy", "require-corp");
    headers.set("Cross-Origin-Resource-Policy", "same-origin");

    if (GZIPPED.test(url.pathname)) {
      // These assets are stored already gzip-compressed by build-web.sh.
      headers.set("Content-Encoding", "gzip");
      // Content-Length from the asset is the compressed size; drop it and let
      // the runtime frame the response so a re-compress pass can't desync it.
      headers.delete("Content-Length");
    }

    return new Response(asset.body, {
      status: asset.status,
      statusText: asset.statusText,
      headers,
    });
  },
};
