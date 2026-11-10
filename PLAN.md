# Plan — one CamAnime design, served by both hosts

Both hosts ship the same `/static` tree, so every task below is a change to shared
CSS/JS or to the two renderers' markup — never a fork of the design.

Status key: done · in progress · blocked

## Milestone 1 — one stylesheet set on both hosts · done
Identical `base.css`, `sync.css`, `header-layout.css` pins, then one additive
design layer (`static/css/redesign.css`) loaded last so the templates never had to
be rewritten. Every pin change is made in the 13 templates *and*
`cloudflare/src/pages.js` in the same commit, then bumped together.

## Milestone 2 — tokens, layout floor, motion · done
1. **One token set.** Colours, type scale, spacing, radii, shadows and motion
   durations live in `base.css` `:root`; `redesign.css` derives its own scale from
   those tokens rather than declaring new literals.
2. **No horizontal overflow, 360 → 1920.** Verified at 360/414/768/1280/1920 on
   `/`, `/anime/<id>`, `/watch/<id>/<ep>` across both hosts — `scrollWidth == clientWidth`
   everywhere.
3. **Control states.** Hover, `:focus-visible`, active, disabled on buttons, inputs,
   tabs and card links; 44 px targets on phones.
4. **Motion.** `static/css/motion.css` + `static/js/motion.js`: shared easing tokens,
   IntersectionObserver reveals, nothing hidden without JS, full
   `prefers-reduced-motion` fallback. 10/10 motion checks.
5. **Response time.** Immutable caching for pinned assets on the worker and a short
   edge page cache for anonymous `/` and `/anime/:id`; measured mirror TTFB ~0.75 s.

## Milestone 3 — media player · in progress
6. **Player chrome.** Progress/buffer bar, time labels, volume, captions when tracks
   exist, fullscreen; controls fit at 360 px and in `100dvh`.
   *Verify:* play a real title on both hosts; controls fit at 360 px; no clipped bar.
7. **Resume and progress.** Position saves keep hitting the existing endpoints
   unchanged and the bar restores the saved position.
   *Verify:* play, reload, position restored; request bodies unchanged for build 23.

## Milestone 4 — admin dashboard · blocked
8. **`/owner-console` at every width.** Fixed: token cycle removed, 44 px controls,
   full-width forms under 414 px, panel headings wrap.
9. **Tool parity and working actions.** Every admin control must return a real
   response on both hosts.
   *Blocked:* the supplied login returns 401 on Render and the mirror, and no account
   exists for that email. Needs a working credential (or `ADMIN_PATH` + password).
   Also outstanding: delete the accidentally created `probe` user (no delete route).

## Milestone 5 — release parity · in progress
10. **One version, one APK.** `2.12.0` build `23` agreed on both hosts before this
    work started; `/get/android` returns the same 59,434,094 bytes from both.
    `scripts/check-parity.mjs` asserts pins, version and APK size.
11. **Close the six remaining mismatches.** The gate currently fails because
    `/download` and `/developers` load different assets per host
    (`base.css`, `header-layout.css`, `site.js`, `motion.js`, `release-schedule.js`).
    *Verify:* `node scripts/check-parity.mjs` exits 0.

## Milestone 6 — sub/dub plumbing and providers · not started
12. **Language truth in the data model.** Each episode records audio tracks and
    subtitle tracks as facts from the source; no inferred dubs, no invented subtitle
    tracks, sub-only titles labelled sub-only.
    *Verify:* a fixture per provider asserting the parsed languages.
13. **Dub routing with fallback.** Dub selection prefers a dub source when one
    exists, falls back to the sub source otherwise, and shows a plain "dub not yet
    available" message instead of failing. Sub playback is unchanged.
    *Verify:* both paths plus a missing-episode case, on both hosts.
14. **Provider additions without regressions.** New scrapers land behind the existing
    provider interface, with timeouts, retries and a provider-specific error that
    leaves the fallback chain intact. No provider removed.
    *Verify:* existing providers still resolve; the new one fails cleanly when
    unreachable.
15. **APK rebuild and version bump.** Only after 12–14 pass: bump the version in
    every place the gate reads, build, publish, and re-run the parity gate.
    *Blocked on:* a working Android toolchain on this machine — a version bump with
    no artifact behind it would hand users a broken download.

## Stage checkpoints
- Design → happens next; it formalises the tokens and type scale already shipped.
- Security review → after Milestone 4 (the admin surface is the sensitive part).
- Test thoroughly → Milestones 2–5 checks in a real browser on both hosts, then 12–14.
- Ship → worker deploy + Render auto-deploy, then the parity gate must exit 0.

## Guardrails
- No class or id renames that `site.js`, templates or the Android WebView depend on.
- API response shapes stay the same, so build 23 keeps working.
- Deploy: `cd cloudflare && npx wrangler deploy`; Render redeploys on push.
- Perceptible delay between a deploy and the mirror serving new pins is ≤ 60 s
  (edge page cache, 15 s stale window).
