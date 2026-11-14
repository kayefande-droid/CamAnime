# CamAnime — instructions for anyone (human or agent) changing this repo

## Never remove the streaming providers or their servers

**Standing instruction from the owner, 15 November 2026 — this one is not
optional and it overrides any refactor, cleanup, simplification, "unused code"
sweep, provider audit, or security-driven removal:**

> never remove my streaming servers and providers that stream and provide anime
> downloads. the only thing you can do is increase the speed or fetch speed of
> the providers and streaming. don't you ever put it away from the website.

In practice:

- Do **not** delete, disable, hide, deprecate or "temporarily switch off" any
  provider class, provider helper, mirror host, stream/download route, or the
  provider list the player and download button read from. That means
  `streaming_providers.py` (`AnimeHeavenProvider`, `AnikotoProvider`,
  `YouTubeTrailerResolver`, `StreamingManager`), the watch/download routes in
  `app.py`, and the worker versions of the same in `cloudflare/src/`.
- Do **not** remove a provider because it is slow, flaky, rate-limited, or
  returns few sources. Diagnose it, retry it, cache it, parallelise it.
- The only permitted change in this area is **making fetching and streaming
  faster or more reliable** — more concurrency, tighter timeouts with retries,
  better caching, connection pooling, prewarming, narrower payloads, faster
  mirrors preferred but never at the cost of dropping a mirror that works.
- If a provider is genuinely dead upstream, say so and leave the code in place;
  the owner decides whether it is replaced.

Related notes:

- AnimeHeaven mp4 mirrors must be real episode files (size-checked) and never
  the promo stub; Anikoto must keep both SUB and DUB servers.
- Changes to provider behaviour need a live fetch test on both hosts (Render
  origin and the Cloudflare mirror) before shipping.
