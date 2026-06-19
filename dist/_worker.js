// Cloudflare Pages advanced-mode worker for a Godot 4 Web build.
//
// Only index.wasm is a problem: at ~38 MB it exceeds Cloudflare Pages' 25 MiB
// per-file limit, so scripts/build-web.sh stores it pre-gzipped (~10 MB). The
// catch: Cloudflare strips a manually-set Content-Encoding from a Worker
// response and then compresses the body itself, so we cannot simply relabel the
// gzip bytes. Instead we DECOMPRESS the wasm here and hand Cloudflare plain
// bytes; Cloudflare then applies its own (correct) Brotli/gzip on egress.
//
// Every other asset is stored uncompressed and served normally. In advanced
// mode the _headers file is ignored, so the cross-origin isolation headers
// Godot's threaded build needs (SharedArrayBuffer) are set here for all assets.

function isolate(headers) {
  headers.set("Cross-Origin-Opener-Policy", "same-origin");
  headers.set("Cross-Origin-Embedder-Policy", "require-corp");
  headers.set("Cross-Origin-Resource-Policy", "same-origin");
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.pathname.endsWith("/index.wasm")) {
      // Fetch the raw stored bytes with no edge transform, then gunzip.
      const probe = new Headers(request.headers);
      probe.delete("Accept-Encoding");
      probe.delete("Range");
      const asset = await env.ASSETS.fetch(
        new Request(new URL("/index.wasm", url), { method: "GET", headers: probe })
      );

      if (asset.ok && asset.body) {
        const headers = new Headers(asset.headers);
        headers.delete("Content-Encoding");
        headers.delete("Content-Length");
        headers.set("Content-Type", "application/wasm");
        headers.set("Cache-Control", "public, max-age=31536000, immutable");
        isolate(headers);
        return new Response(asset.body.pipeThrough(new DecompressionStream("gzip")), {
          status: 200,
          headers,
        });
      }
    }

    const asset = await env.ASSETS.fetch(request);
    const headers = new Headers(asset.headers);
    isolate(headers);
    return new Response(asset.body, {
      status: asset.status,
      statusText: asset.statusText,
      headers,
    });
  },
};
