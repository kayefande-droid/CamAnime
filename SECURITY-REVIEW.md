# CamAnime — security review

Date: 11 November 2026, re-reviewed 14 November 2026 · Scope: the Flask app on Render, the Cloudflare mirror in
`cloudflare/`, the shared `static/` tree, and the Android client's API surface.

## Re-review, 14 November 2026

The 11 November review still holds — no finding below was reopened. This pass
re-ran the scanners against the tree as it stands after the SEO and page-skin
work, and re-checked the live hosts.

| Tool | Command | Result |
| --- | --- | --- |
| gitleaks 8.30.1 (history) | `gitleaks git -v` | 263 commits, 211 hits: 208 `generic-api-key` and 2 `curl-auth-header` are the same placeholder/`.venv`/lockfile noise as before (`ca_live_your_key_here`, package metadata, build caches); the one `gcp-api-key` is the public Firebase config key (L3). No new secret in history. |
| gitleaks 8.30.1 (working tree) | `gitleaks dir .` | 428 hits, all inside vendored or ephemeral paths (`.venv`, `node_modules`, `.scan` reports) plus the local-only `cloudflare/.cf-deploy.env`, `cloudflare/.cf-audit.env`, `.e2e/`, `.shorebird.env`. Every one of those files is untracked and git-ignored (`git ls-files` = 0, `git check-ignore` = yes), and `git log -S"cfat_"` shows the Cloudflare tokens were never committed. |
| pip-audit | `pip-audit -r requirements.txt` | **No known vulnerabilities found** (Flask 3.1.3, Werkzeug 3.1.9, requests 2.33.0, gunicorn 23.0.0). |
| npm audit | `npm audit --omit=dev` at the root and in `cloudflare/` | 0 vulnerabilities in both. |
| bandit | `bandit -r` over the 11 server modules | 0 high. 5 medium, all triaged: 3× B608 placeholder-list interpolation with bound values (`camanime_platform.py:300`, `:801`, `push.py:243`), 1× B104 `app.run(host="0.0.0.0")` guarded by `__main__` for the local dev server, 1× B310 `urlopen` in `d1db.py` whose URL comes from `D1_API` plus the configured account/database id, never from a request. |
| semgrep | `semgrep scan --config auto` | **Could not run**: the install again timed out on this Windows host (240 s) and no `semgrep` binary lands. Covered by bandit plus the manual read of the code added since the last review. |
| osv-scanner / OWASP ZAP | — | **Could not run**: the osv-scanner release asset would not download from this machine and there is no Docker for the ZAP baseline. Covered by pip-audit + npm audit and the hand-run abuse cases below. |

What changed since the last review, and why it is safe:

- **New head tags and JSON-LD.** Every page now emits a canonical, OG/Twitter
  card and structured data. Canonicals are built from `request.path` or
  `url.origin` and pass through Jinja autoescape (`__CA_CANONICAL__` is filled
  by `xmlEscape` on the Worker); JSON-LD is emitted with `| tojson` on the
  origin and `JSON.stringify(...).replace(/</g, "\\u003c")` on the mirror, so a
  title containing `</script>` cannot break out of the block.
- **Search results echo the query.** `q` now appears in the page title and meta
  description on both hosts. Verified escaped: a request for `";alert(1);//`
  renders `&#34;;alert(1);//` (origin) and `&quot;;alert(1);//` (mirror). The
  firewall refuses a query containing `<script` with a 404 before any view runs.
- **`static/js/site-nav.js`** (new) touches only `classList`, `setAttribute` and
  `focus`; no `innerHTML`, no `eval`, no data from the URL. It loads from
  `'self'`, which the CSP already allows.

Live checks on 14 November:

- Both hosts return the full header set (CSP, HSTS, `nosniff`, `X-Frame-Options`,
  Referrer, Permissions, COOP/CORP). The mirror returns all six.
- SSRF guards: `/api/proxy/hls` answers 400 for `http://10.0.0.5/…` and
  `http://169.254.169.254/…` on both hosts, 404 for `file:///etc/passwd`.
- `/search` is `noindex` and absent from both sitemaps; `/developers` is
  indexable on both.

No critical or high finding is open. The medium and low items from 11 November
keep the status recorded below.

---

Both hosts serve the same pages from one static tree, so anything found on one
was checked on the other. Every critical and high finding below is fixed and
verified; the medium and low items that remain are listed with the reason.

## Scanners

| Tool | Command | Result |
| --- | --- | --- |
| gitleaks 8.28.0 (working tree) | `gitleaks dir .` | 217 hits, all triaged: 209 in `.venv`/build output/local ignored env files, 8 real matches that are placeholders or client config (see L3). Nothing to rotate. |
| gitleaks 8.28.0 (history) | `gitleaks git .` | 197 commits, 3 hits: `google-services.json` client key and two copies of the documented `x-api-key: ca_live_your_key_here` placeholder. No live secret was ever committed. |
| pip-audit | `pip-audit -r requirements.txt` | 3 vulnerable packages pinned (Flask 3.0.3, Werkzeug 3.0.3, requests 2.31.0) → fixed by upgrading; re-run reports **no known vulnerabilities**. |
| npm audit | `npm audit --omit=dev` in `cloudflare/` | 0 vulnerabilities (the worker has no runtime dependencies). |
| bandit | `bandit -r app.py camanime_platform.py developer_api.py mfa.py push.py releases.py streaming_providers.py` | 0 high severity. 4 medium: 3 B608 SQL-string warnings that are placeholder-list interpolation (`",".join("?" …)`) — false positives, values are bound; 1 B104 bind-all-interface for the local dev server. |
| semgrep | `semgrep scan --config auto` | **Could not run**: installing semgrep timed out on this Windows machine and the native `semgrep-core` binary is not supported here. Compensated with bandit plus the manual review below. |
| OWASP ZAP baseline | `docker run … zap-baseline.py` | **Could not run**: no Docker on this machine. Replaced with a header/cookie/TLS check against both live hosts (`curl -D -`) and the manual abuse cases below. |

## Findings

| # | Finding | Severity | Where | Fix | Status |
| --- | --- | --- | --- | --- | --- |
| H1 | **Stored XSS through comment stickers.** `sticker` was stored exactly as posted and injected into the page as markup (`innerHTML`), so any visitor could plant script that ran for every other viewer of that anime page. | High | `camanime_platform.add_comment`, `cloudflare/src/api.js` `postComment`, `static/js/community.js` `card()` | Sticker must be one of the published set on both servers, and the widget escapes it on render. A post whose only content was invalid sticker markup is now rejected. | Fixed — `tests/test_security_fixes.py`, `cloudflare/test/comment-sticker.test.mjs` |
| H2 | **Privilege escalation via password reset.** `/api/admin/password` let any `developer` or `support` login reset *any* account's password, including the owner's — a full owner takeover. | High | `app.py` `api_admin_password` | Cross-account reset is owner-only; other privileged roles can only change their own password (still needs the current one). | Fixed — two tests drive both paths |
| H3 | **The mirror sent no security headers.** No CSP, HSTS, `nosniff`, `X-Frame-Options`, Referrer or Permissions policy — clickjacking and MIME sniffing were open on the Cloudflare host while Render was protected. | High | `cloudflare/src/index.js` | Every response now passes through `withSecurityHeaders()`, using the same values as the Render `after_request` hook. 204/304/101 responses are passed without a body. | Fixed — verified live with `curl -D -`; `cloudflare/test/security-headers.test.mjs` |
| H4 | **Vulnerable dependencies.** Pinned Flask 3.0.3, Werkzeug 3.0.3 and requests 2.31.0 carried published advisories. | High | `requirements.txt` | Upgraded to Flask 3.1.3, Werkzeug 3.1.9, requests 2.33.0; full suite re-run against the new versions. | Fixed — `pip-audit`: no known vulnerabilities; 185 pytest pass |
| M1 | **SSRF into private networks.** The media proxy blocked loopback and link-local addresses but not RFC1918 space or CGNAT, so a request could reach an internal host. | Medium | `app.py` `_safe_upstream_url` | Only globally routable addresses are accepted (`ip.is_global`), which covers private, loopback, link-local, multicast, unspecified and reserved ranges. | Fixed — verified live: `/api/proxy/hls?url=http://10.0.0.5/…` now returns 400 on both hosts |
| M2 | **CSRF.** State-changing endpoints accept form bodies and there is no per-request token. | Medium | `app.py` POST routes | Mitigated rather than removed: session cookies are `SameSite=Lax`, so a browser does not attach them to a cross-site POST; every privileged route is JSON-or-form with a server-side role check. A token or strict `Origin` check was deliberately not added: the Android WebView posts to the same endpoints and a wrong guess would break build 23 for real users, which the project rules forbid. | Open, accepted |
| M3 | **Open media proxy.** `/api/proxy/*` and `/api/download/video` fetch a caller-supplied URL for anyone, which is abuse-prone for bandwidth and reputation. | Medium | `app.py` | Rate limited (300 requests / 10 min per IP) and every URL passes the SSRF and ad-network guards. `CAMANIME_MEDIA_HOSTS` can pin an allowlist per deployment. | Open, accepted (needed for playback) |
| M4 | **CSP allows inline scripts** (`script-src 'unsafe-inline'`). | Medium | `app.py`, `cloudflare/src/index.js` | Inline scripts cannot be removed without rewriting every template and the mirror's SSR output. The risk is bounded because no template uses `|safe`, user text is escaped, and H1 removed the only markup injection path. | Open, accepted |
| L1 | CORS `Access-Control-Allow-Origin: *` on proxy, subtitle and download responses. | Low | `app.py` | Intentional: the player fetches from the app origin and the mirror. No `Allow-Credentials`, so no session or cookie data is exposed. | Accepted |
| L2 | Rate limiting keys on the first `X-Forwarded-For` value. | Low | `app.py` `_client_ip` | Render and Cloudflare overwrite the header with the real client address, so a client cannot rotate the key through their own header. | Accepted |
| L4 | **The Windows virtualenv was committed.** 2,374 of the repo's 2,776 tracked files were `.venv/`, so every clone carried a prebuilt interpreter and thousands of site-packages files. No secret was in it (gitleaks read the whole tree: package metadata strings only), but it is the one place a future `pip install` could quietly commit a token, and it inflated the Render checkout. | Low | `.venv/` | Removed from the index (`git rm -r --cached .venv`) and added to `.gitignore`; the files stay on local disk and Render builds from `pip install -r requirements.txt`, so nothing deploys differently. | Fixed — 14 Nov 2026 |
| L3 | `mobile/camanime_app/android/app/google-services.json` is tracked and contains a Firebase API key; local `*.env` files with deploy tokens sit untracked-but-ignored. | Low | repo root, `mobile/` | A Firebase key in an Android app config is public by design and is protected by the package-name/SHA-1 restriction in the console, not by secrecy. The env files are git-ignored and untracked (`git check-ignore` confirmed). | Accepted — restrict the key to the app's package and signing SHA-1 |

## What was checked and held

- **Sessions.** `HttpOnly`, `SameSite=Lax`, `Secure` by default (opt-out only for
  local HTTP), 14-day lifetime, secret from `CAMANIME_SECRET` or a git-ignored
  key file — never committed.
- **Authorisation.** `/owner-console` and every `/api/admin/*` route enforce a
  server-side role check; the unlisted admin path is obscurity on top, never the
  gate. Role changes are owner-only and audited. History rows are scoped to the
  signed-in account, proven by `tests/test_auth_isolation.py`.
- **Brute force.** Login (web form and API), register, comment, like, rating,
  download and admin routes are rate limited per IP; the login test asserts 429
  and `Retry-After`. Unknown emails and wrong passwords return the same error.
- **Input handling.** Request bodies are capped at 2 MB, ids go through route
  converters or `_safe_site_id`, `next=` is restricted to same-site paths, and all
  SQL is parameterised (the three bandit hits are placeholder lists).
- **Secrets in the client.** `docs/SECURITY.md` documents why client code cannot
  be secret; no provider URL, key or token is shipped to the browser.
- **Headers and transport.** Both hosts now return the same CSP, HSTS,
  `nosniff`, frame, referrer, permissions and cross-origin headers.
- **Hosting.** `app.run(debug=False)`; no directory listing; no stack traces in
  responses (errors render the themed page); `.env`, `.git`, `wp-admin` and
  similar scanner paths are refused before any view.

## Still open, and what it would take

- M2 CSRF token / strict `Origin` check — do it together with a mobile build that
  can be verified, not before.
- M4 nonce-based CSP — needs the inline scripts out of every template and out of
  the mirror's SSR strings.
- M3 host allowlist — set `CAMANIME_MEDIA_HOSTS` once the licensed CDN hosts are
  fixed.
- Re-run semgrep and a ZAP baseline scan on a machine with Docker and a
  supported semgrep install before launch.
