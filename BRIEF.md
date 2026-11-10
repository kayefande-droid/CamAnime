# Brief — CamAnime design system, shared by both hosts

## What this is
CamAnime ships twice: the Flask/Jinja app on Render (`camanime.onrender.com`) and the
Cloudflare Worker mirror (`camanjme.camanime.workers.dev`). Both already serve the
same `/static` directory, so the design is genuinely one system — the goal is to make
that visible and consistent on every page, then raise the quality of the parts that
are weakest: layout at small and large widths, the media player, and the admin
dashboard.

This is not a rewrite. The stack stays: Flask + Jinja templates and Werkzeug sessions
on Render; a Worker with D1, R2 and the same static assets on Cloudflare.

## Decisions
- **Users:** anonymous visitors browsing and watching, signed-in members (library,
  resume points, watchlist), and one admin account (`owner-console`).
- **Core actions:** find something to watch and play it; resume where you stopped;
  download the Android APK — all identical on both hosts.
- **Data:** accounts, sessions, watch history/resume points, watchlist, push tokens.
  No payments, no health data. The only sensitive value is the admin password (hashed).
- **Styling:** plain modern CSS with tokens declared once in `:root` inside
  `static/css/base.css`; `sync.css` carries the player and page components;
  `header-layout.css` carries the two-row header. No framework, no component library.
- **Design direction:** keep the CamAnime brand (Sora display / Outfit body, dark
  surfaces). One type scale, one spacing scale, one set of radii and shadows, applied
  on both hosts.
- **Hosting and backend:** unchanged — Render plus Cloudflare Workers/D1/R2.
- **Billing:** none.

## Constraints (from the user)
- Do not break streaming providers, downloaders, or the APK-facing API paths.
- Every HTML page must match across the two hosts.
- The Android release version must be identical on both: currently `2.12.0` build `23`.
- The player must keep working and gain polish, not new invented controls.

## Definition of done for a page
Same stylesheets at the same version on both hosts, identical markup classes for the
page's components, no horizontal overflow from 360 px to 1920 px, and every control
with hover, focus-visible and disabled states.

## Assumptions
- Visual direction continues the existing dark brand rather than a new identity.
- Admin-only tooling is reached at `/owner-console` on both hosts.
