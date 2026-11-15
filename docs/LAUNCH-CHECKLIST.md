# Launch checklist — CamAnime, 15 November 2026

Walked item by item against the two live hosts:

- Origin — <https://camanime.onrender.com> (Flask + Jinja on Render, auto-deploy from `main`)
- Mirror — <https://camanjme.camanime.workers.dev> (Cloudflare Worker `camanjme` + D1 + R2, `wrangler deploy`)

## Deploy

| Item | Status | Evidence |
| --- | --- | --- |
| Production build passes with no unexplained warnings | **Done** | `pytest tests -q` 215 passed; `npm --prefix cloudflare test` 88 passed |
| Env vars and secrets set on the host, production keys separate, nothing secret in the client bundle | **Done** | Render dashboard holds `CAMANIME_SECRET`, `CAMANIME_ADMIN_*`, `CAMANIME_D1_*`; worker uses its own bindings plus `cloudflare/.cf-deploy.env` (git-ignored). No key is referenced from any template or shipped JS — the developer API returns keys only over an authenticated session. |
| Database migrations applied; backup or point-in-time restore enabled | **Done (D1) / Open (file fallback)** | D1 schema is applied by the worker's own migrations and by `camanime_platform.py` on the origin; Cloudflare D1 offers Time Travel restores (30 days). The SQLite file fallback on a dev machine has no backup — it holds no production data. |
| Domain connected, HTTPS, `www`/apex redirect, HSTS | **Ready, needs a domain** | Both hosts answer on HTTPS with `strict-transport-security: max-age=31536000; includeSubDomains`. `www` now 301s to the configured apex on both hosts and every canonical/sitemap/JSON-LD URL reads `CAMANIME_PUBLIC_ORIGIN`; no domain is connected yet, so the platform hostnames remain the canonical origin. |
| Preview and staging are `noindex` or protected | **Not applicable** | Both deployments are the production site; there is no separate preview environment. The owner console is behind `ADMIN_PATH` + role, and `/search` is noindex. |

## Search and sharing

| Item | Status | Evidence |
| --- | --- | --- |
| Unique `<title>` and description, canonical URL, `lang` on `<html>` | **Done** | The browser check reports title, description, canonical and `lang: en` for `/`, `/watch/…` and `/download`; the link crawl found no duplicate canonicals. |
| Open Graph and Twitter cards with a 1200×630 image | **Done** | New `static/brand/og-card-1200x630.png`, referenced by every public template and every worker page. |
| `robots.txt`, `sitemap.xml`, JSON-LD where useful | **Done** | Both hosts return 200 for both files; `/privacy` added to each sitemap; `WebSite`+`SearchAction` JSON-LD on the home page, `SoftwareApplication` on `/download`, `Organization` on the origin home. |
| Favicon and app icons; a useful 404 page | **Done** | SVG + PNG favicons, apple-touch icon and the web manifest on every page; `/this-page-does-not-exist` → 404 with the themed error page on both hosts. |

## Commerce

**Not applicable** — the site has no store, no payments and no paid plans.

## Email

**Not applicable** — CamAnime sends no email. Accounts are created in-app, notifications are in-app announcements, and the app's updates arrive through the release policy endpoint rather than a mailing list. There is therefore no sending domain, SPF/DKIM/DMARC or deliverability work.

## Legal and privacy

| Item | Status | Evidence |
| --- | --- | --- |
| Privacy policy | **Done** | `/privacy` on both hosts, written from what the code actually stores (email, display name, PBKDF2 password hash, `ca_session` cookie, comments, ratings, watch history, push token). |
| Terms | **Done** | The same page states the content/usage terms: it links to third-party hosted media, does not host video, and abusive accounts can be removed. |
| Cookie consent | **Not applicable** | The only cookie is the first-party, HttpOnly session cookie set when someone chooses to sign in. There are no advertising, analytics or third-party tracking cookies. |
| Contact details | **Done** | The issue tracker (`github.com/kayefande-droid/CamAnime/issues`) is the published contact and deletion channel; no postal address is invented. |

## Observability

| Item | Status | Evidence |
| --- | --- | --- |
| Error tracking and uptime checks with alerts | **Wired, needs a destination** | Origin and Worker both post 5xx to `CAMANIME_ALERT_WEBHOOK` / `ALERT_WEBHOOK` (throttled to one per kind per 5 minutes), and the Worker's 5-minute cron polls both `/healthz` endpoints and alerts on failure. No webhook URL has been set yet, so nothing is sent. |
| Analytics that respects consent | **Not applicable / Done** | No third-party analytics. The origin counts visits in its own `counters` table and the worker counts edge visits in D1 — first-party, aggregate, no identifiers. |

## Handover

| Item | Status | Evidence |
| --- | --- | --- |
| README: run, deploy, secrets, rollback, accounts | **Done** | `README.md` "Quick start", "Ship status", "Operations & privacy" sections. |
| Test and security reports linked, open items listed | **Done** | `TEST-REPORT.md`, `TEST-PLAN.md`, `SECURITY-REVIEW.md`; open items repeated in the README. |
| User knows the next steps | **Done** | Summarised in the handover message: watch the first week for provider drift, then the open items below. |

## Open after launch

1. **Alert destination.** Error and uptime alerting is wired on both hosts; set `CAMANIME_ALERT_WEBHOOK` on Render and `ALERT_WEBHOOK` on the Worker to start receiving it.
2. **`CAMANIME_D1_TOKEN` on Render.** The origin only writes to D1 when this is set in the dashboard; until then the origin keeps its own store.
3. **Custom domain.** The wiring is in place and needs a domain: set `CAMANIME_PUBLIC_ORIGIN` (origin) and `PUBLIC_ORIGIN` (Worker), add the Worker route and the Render custom domain, and www 301s to the apex on both hosts. Steps are in the README's *Custom domain* section.
5. **Sitemap ownership.** The mirror's sitemap lists catalogue URLs the origin's does not — decide one source of truth before submitting either to search engines.
