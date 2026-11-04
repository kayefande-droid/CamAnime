CAMANIME CLOUDFLARE — RETIRED RENDER PROXY (folder kept only until dashboard config moves)

This folder's old job — proxying https://camanime.onrender.com through a Worker —
was removed on purpose. The independent Cloudflare CamAnime application now lives in:

    cloudflare/          ← Workers + D1 + R2 + repo static assets
    cloudflare/README.md ← full architecture + setup + residual limits

Actions for the Cloudflare dashboard (one-time):
  1. Workers Builds: change the root directory from /cloudflare-worker to /cloudflare
     (build `npm install`, deploy `npm run deploy`, production branch main).
  2. Delete this Workers Builds connection afterwards, or keep it — the deploy
     script below forwards to cloudflare/ so both roots keep deploying the same app.

The worker name stays `camanjme` everywhere (https://camanjme.camanime.workers.dev).
