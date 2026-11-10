# Plan — one CamAnime design, served by both hosts

Both hosts ship the same `/static` tree, so every task below is a change to shared
CSS/JS or to the two renderers' markup — never a fork of the design.

Milestone 1 is already done: identical stylesheet set and versions on both hosts
(`base.css`, `sync.css`, `header-layout.css` at `20261111-ui` / `20261111-header`).

## Milestone 2 — tokens and layout floor

1. **One token set.** Audit `static/css/base.css` `:root` for colours, type scale,
   spacing, radii, shadows and motion durations. Any literal colour or font-family
   later in `base.css`/`sync.css` moves into a token.
   *Verify:* `grep` for `#[0-9a-f]{3,6}` and `font-family` outside `:root` returns only
   allowed exceptions (SVG fills, provider logos).
2. **No horizontal overflow, 360 px → 1920 px.** `overflow-x: clip` on `html, body`,
   capped centred container, and a check of `/`, `/anime/<id>`, `/watch/<id>/<ep>`,
   `/library`, `/download`, `/owner-console` at 360, 414, 768, 1024, 1280, 1920.
   *Verify:* `document.documentElement.scrollWidth <= clientWidth` at each width, and
   screenshots at 360/1280.
3. **Control states.** Every button, input, tab and card link gets hover,
   `:focus-visible` (instant, 3:1 against its background), active and disabled.
   *Verify:* keyboard tab-through on each page shows a visible focus ring; contrast
   checked for body text (4.5:1) and large text/icons (3:1).

## Milestone 3 — media player

4. **Player chrome.** Progress bar with buffered range, time labels, volume, captions
   toggle when tracks exist, fullscreen — responsive at 360 px and in `100dvh`
   fullscreen, controls never overflowing the bar.
   *Verify:* play a real title on both hosts; controls fit at 360 px; fullscreen has no
   clipped bottom bar; keyboard shortcuts still work.
5. **Resume and progress.** Position saves continue to hit the existing endpoints
   unchanged; the bar reflects the saved position on load.
   *Verify:* play, reload, position restored; `POST` bodies unchanged so the API stays
   compatible with build 23 of the app.

## Milestone 4 — admin dashboard

6. **`/owner-console` at every width.** Tables become scrollable/cardified under
   720 px, each panel has loading, empty and error states.
   *Verify:* every existing admin action (user list, ban, push test, uploads, catalogue
   tools) still returns 200 on Cloudflare D1 and on Render, and the layout holds at
   360 px.
7. **Tool parity.** Confirm each admin tool present on Render exists on the Worker (or
   is documented as intentionally absent).
   *Verify:* a checklist run against both hosts, recording status codes.

## Milestone 5 — release parity

8. **One version, one APK.** `2.12.0` build `23` appears identically in `pubspec.yaml`,
   `version_gate`, `cloudflare/src/release.js`, the Worker's `/download`, Render's
   `/download`, and the R2 object served by `/get/android`.
   *Verify:* a script that reads all five and exits non-zero on any mismatch.

## Stage checkpoints
- Design → settle tokens and type scale before Milestone 2 lands.
- Security review → after Milestone 4 (admin surface changed).
- Test thoroughly → run Milestones 2–5 checks in a real browser on both hosts.
- Ship → deploy Worker + Render, then re-verify parity.

## Guardrails
Streaming provider calls, downloader endpoints and every `/api/app/*` path the Android
app uses stay byte-compatible; layout work must not rename classes the app's webviews
or the templates depend on.
