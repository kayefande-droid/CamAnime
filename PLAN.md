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

## Milestone 3 — media player · done
6. **Player chrome.** Progress/buffer bar, time labels, fullscreen, error surface,
   phone-width fit. *Verified in Chrome on both hosts at 360 and 1280:* `<video>`
   reaches `readyState` 1 or 4, progress and fullscreen controls present, two time
   labels, `#playerError` in the DOM, zero horizontal overflow, controls bar no
   wider than the viewport (`scripts`-adjacent probe `.judgment/player-check.mjs`).
7. **Resume and progress.** Guests now actually resume: the position is written to
   `camanime_resume_<animeId>_<ep>` on `timeupdate`/`pause`/`pagehide`, skipped
   under 5 s and past the last 10 s, and re-applied across
   `loadedmetadata`/`loadeddata`/`canplay`/`playing`/`durationchange` because
   server fallback reassigns `src` and zeroes the position. Signed-in members keep
   their existing `/api/history` sync, unchanged.
   *Verified:* a saved 12 s position came back on a fresh load; clearing the key
   starts at 0.0 s. Request bodies to `/api/history` untouched, so build 23 is safe.

## Milestone 4 — admin dashboard · blocked
8. **`/owner-console` at every width.** Fixed: token cycle removed, 44 px controls,
   full-width forms under 414 px, panel headings wrap.
9. **Tool parity and working actions.** Every admin control must return a real
   response on both hosts. The light/dark appearance toggle now renders in the same
   place on both hosts at 1280, and the phone header paints opaque below 900 px so
   content never shows through it.
   *Verified:* 18 screenshots across `/`, `/anime/<id>`, `/watch/<id>/<ep>` at 360 and
   1280 on both hosts — every page 200, zero horizontal overflow.
   *Blocked:* the supplied login returns 401 on Render and the mirror, and no account
   exists for that email. Needs a working credential (or `ADMIN_PATH` + password).
   Also outstanding: delete the accidentally created `probe` user (no delete route).

## Milestone 5 — release parity · in progress
10. **One version, one APK.** `2.12.0` build `23` agreed on both hosts before this
    work started; `/get/android` returns the same 59,434,094 bytes from both.
    `scripts/check-parity.mjs` asserts pins, version and APK size.
11. **Close the six asset mismatches.** · done — `download.html` gained
    `base.css` + `header-layout.css`, `developers.html` gained `site.js` +
    `motion.js`, the worker head gained `release-schedule.js`, and `login.html`
    gained `base.css` + `header-layout.css` so the sign-in card matches the mirror.
    *Verified:* the gate reports `/`, `/download`, `/developers` and `/login` all at
    8/8 matching pins, version `2.12.0/23` and identical 59,434,094-byte APKs on
    both hosts.

    The gate compares, in order: the `<head>` asset pins of every page both hosts
    serve, the advertised app version, the `/get/android` byte count, the status of
    twelve routes, the internal link inventory and both `/sitemap.xml` sets. It exits
    1 on any divergence, so it can gate a deploy. Run it after every push to Render
    and every `wrangler deploy`.
12. **Route-level parity.** Trailing slashes 308-redirect to the canonical path on
    both hosts, the mirror's `/download` is now the full Render page, and the
    mirror's `/schedule` 302s to `/?schedule=open` exactly as Render does.
    *Still open (route coverage, not styling):* the mirror 404s `/scraper`, `/promo`
    and `/advert`, Render 404s `/library`, `/owner-console` answers 401 on the mirror
    and 200 on Render, the mirror sitemap lists 4 URLs against Render's 37, and
    Render never links `/library`, `/browse` or `/search` from its own pages.
13. **Home structure and screen states.** A genre browse rail and a continue-watching
    row give the grid real structure; the continue-watching fetch, the schedule and
    the catalogue each show a plain error line with a retry instead of an empty gap.
    The watch page explains a resume jump with a "resuming at mm:ss" note that clears
    after a few seconds.
    *Verified:* resume note observed in Chrome at 12:04 against a local 21 m 40 s clip,
    `currentTime` 724 / duration 1300; continue-watching error line and schedule retry
    button present on both hosts.

## Milestone 6 — sub/dub plumbing and providers · design approved, not built
14. **Sub/dub design.** `docs/sub-dub-model.md` records the proposed model: an
    additive `audio` field (`sub` / `dub` / `unknown`) read from the source, with the
    player preferring a dub source when one exists and falling back to sub with a
    plain "dub not yet available" message. Nothing is implemented yet — it is
    deliberately left out until the player's audio switch lands with it, because a
    label without a real track behind it would be an invented fact.
    *Verify (on implementation):* both paths plus a missing-episode case on both hosts.
15. **Language truth in the data model.** Each episode records audio tracks and
    subtitle tracks as facts from the source; no inferred dubs, no invented subtitle
    tracks, sub-only titles labelled sub-only.
    *Verify:* a fixture per provider asserting the parsed languages.
16. **Dub routing with fallback.** Dub selection prefers a dub source when one
    exists, falls back to the sub source otherwise, and shows a plain "dub not yet
    available" message instead of failing. Sub playback is unchanged.
    *Verify:* both paths plus a missing-episode case, on both hosts.
17. **Provider additions without regressions.** New scrapers land behind the existing
    provider interface, with timeouts, retries and a provider-specific error that
    leaves the fallback chain intact. No provider removed.
    *Verify:* existing providers still resolve; the new one fails cleanly when
    unreachable.
18. **APK rebuild and version bump.** Only after 15–17 pass: bump the version in
    every place the gate reads, build, publish, and re-run the parity gate.
    *Blocked on:* a working Android toolchain on this machine — a version bump with
    no artifact behind it would hand users a broken download.

## Milestone 7 — security review · done
19. **Findings closed.** `SECURITY-REVIEW.md` records every scanner result and
    finding. Four high issues are fixed and verified on both hosts: stored XSS
    through comment stickers, an owner takeover by password reset from a support
    login, the mirror sending no security headers at all, and three dependencies
    with published advisories. The media proxy now refuses every non-global IP.
    Medium items left open with reasons: CSRF (cookie is `SameSite=Lax`; a token
    would risk the Android WebView), the media proxy allowlist, and a nonce CSP.
    semgrep and ZAP could not run here (no Docker, semgrep unsupported on this
    Windows box) — bandit plus a manual review covered the same ground.
    *Verify:* `pytest tests` 185 passed, worker `npm test` 75 passed,
    `pip-audit` clean, `npm audit` clean, gitleaks history triaged.

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
