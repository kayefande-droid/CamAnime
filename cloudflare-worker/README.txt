CAMANIME CLOUDFLARE WORKER (RENDER ORIGIN PROXY)

Worker name on Cloudflare: camanjme
(next serves https://camanjme.<your-subdomain>.workers.dev — Cloudflare only;
Render keeps camanime/camanime.onrender.com untouched for the origin and search.)

What this does:
- Creates a Cloudflare Worker endpoint for CamAnime.
- Forwards requests to https://camanime.onrender.com.
- Streams the upstream response body instead of buffering it.
- Attempts to keep redirects on the Cloudflare hostname.

Important:
- This is a Cloudflare front door/proxy, NOT an independent copy of the Flask backend.
- Render must remain online. Flask, SQLite, scraping, accounts, and streaming still run on Render.
- Test login, search, episode playback, downloads, and redirects before sharing the Cloudflare URL.
- Do not remove or change the existing Render service.

Cloudflare Workers Builds settings:
1. Root directory: /cloudflare-worker
2. Build command: npm install
3. Deploy command: npm run deploy
4. Build output directory: leave blank
5. Production branch: main

If you uploaded these files into the repository, the paths must be:
cloudflare-worker/index.js
cloudflare-worker/wrangler.jsonc
cloudflare-worker/package.json

The GitHub repository must contain the cloudflare-worker folder at its root.
