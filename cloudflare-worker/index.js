const ORIGIN = "https://camanime.onrender.com";

export default {
  async fetch(request) {
    const incoming = new URL(request.url);
    const target = new URL(ORIGIN);

    // Preserve the original path and query string.
    target.pathname = incoming.pathname;
    target.search = incoming.search;

    // Forward method, headers, and streaming request body to Render.
    const upstreamRequest = new Request(target.toString(), request);

    let upstreamResponse;
    try {
      upstreamResponse = await fetch(upstreamRequest, {
        redirect: "manual"
      });
    } catch (error) {
      return new Response("CamAnime origin is temporarily unreachable.", {
        status: 502,
        headers: { "content-type": "text/plain; charset=utf-8" }
      });
    }

    // Keep redirects on the Cloudflare hostname when Render returns
    // an absolute redirect to the original Render domain.
    const responseHeaders = new Headers(upstreamResponse.headers);
    const location = responseHeaders.get("Location");

    if (location) {
      try {
        const redirectUrl = new URL(location, ORIGIN);
        if (redirectUrl.hostname === new URL(ORIGIN).hostname) {
          redirectUrl.protocol = incoming.protocol;
          redirectUrl.host = incoming.host;
          responseHeaders.set("Location", redirectUrl.toString());
        }
      } catch (_) {
        // Leave unusual or relative Location values unchanged.
      }
    }

    // Pass the upstream response body through without buffering it.
    return new Response(upstreamResponse.body, {
      status: upstreamResponse.status,
      statusText: upstreamResponse.statusText,
      headers: responseHeaders
    });
  }
};
