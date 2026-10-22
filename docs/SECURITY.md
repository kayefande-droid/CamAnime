# CamAnime — Security

Copyright (c) 2026 kayefande-droid. All rights reserved. See `LICENSE`.

This document describes the protections CamAnime applies and, just as
importantly, what those protections cannot do.

## Limits of client-side protection (read this first)

**Code that a browser can run, a user can read.** CamAnime's website is
delivered as HTML, CSS and JavaScript. Every one of those files is downloaded to
the visitor's machine to be rendered, so it can always be inspected with browser
developer tools (F12 / Inspect Element), a browser extension, or a plain HTTP
request such as `curl`. There is no `view-source`-proof website, and products
like Crunchyroll, Netflix and Disney+ do not hide their client code either — no
website on the internet can.

CamAnime intentionally does **not** block developer tools, right-click,
or view-source (`static/js/site.js` contains no context-menu, F12 /
Ctrl+Shift+I/J/C / Ctrl+U, or devtools-shield code). Those tricks annoy
legitimate visitors, break accessibility, and are bypassed in seconds
(disabling JavaScript, curl, proxy) — so they were removed on purpose.

They must never be treated as a security control. Anything genuinely secret —
credentials, tokens, admin keys, provider URLs — must live on the server and
never be shipped to the browser.

## Server-side protections

Because client code cannot be secured, protection happens where the browser has
no access:

- **Security headers** applied to every response (`app.py`): `Content-Security-Policy`,
  `X-Content-Type-Options: nosniff`, `X-Frame-Options`, `Referrer-Policy`,
  `Permissions-Policy`, `Strict-Transport-Security`, `Cross-Origin-Opener-Policy`
  and `Cross-Origin-Resource-Policy`.
- **Session cookie hardening**: `HttpOnly`, `SameSite=Lax`, and `Secure` when the
  request arrives over HTTPS.
- **Rate limiting** on authentication, download, proxy and write endpoints, so a
  single client cannot brute-force logins or exhaust server bandwidth.
- **Input validation**: identifiers are type-checked by Flask route converters,
  request bodies have a hard size limit, and query parameters (pagination, audio
  track, page/limit) are range-checked before use.
- **SSRF containment**: the media proxy and download endpoints accept only
  `http`/`https` URLs and reject requests aimed at private, loopback and link-local
  addresses, so the server cannot be used as a bridge into an internal network.
- **Path/advert blocking**: common automated exploit and scanner paths
  (`/.env`, `/.git`, `wp-admin`, `/phpmyadmin`, `xmlrpc.php`, …) are rejected
  before reaching any view.
- **Password storage**: PBKDF2-hashed passwords; no plaintext credentials on disk.
- **Secret handling**: the Flask secret key comes from `CAMANIME_SECRET` or a
  local ignored file — never committed, and never sent to the browser.

## What this does not claim

No web application is immune to attack. These measures raise the cost of the
common automated attacks (scraping, credential stuffing, SSRF, clickjacking,
MIME sniffing). They are not a substitute for an audit, for keeping dependencies
patched, or for legal action against a determined adversary. CamAnime does not
claim to be un-attackable, and no configuration change can make a client-side
codebase unreadable.

## Reporting a vulnerability

Please report security issues privately rather than in a public issue. Contact
the maintainer at **kayefande-droid** on GitHub with a description, reproduction
steps and impact. Do not test against the production site with automated
scanners or load generators. Responsible reports will be acknowledged and fixed
as a priority.
