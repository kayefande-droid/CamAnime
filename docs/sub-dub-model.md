# Sub and dub: data model and player fallback

Status: proposed, not implemented. Nothing in this document changes provider code,
API responses or the player yet. It records what the providers already return, the
shape the player needs, and the order it should fall back in.

## What the providers actually report today

`streaming_providers.py` already classifies audio, it is just not modelled as a
track. Two shapes exist in the resolver output:

| Source | Field | Values seen |
| --- | --- | --- |
| Anikoto / CamStream servers | `type` on each server entry | `sub`, `dub`, `raw` (`streaming_providers.py:898`) |
| Resolver output rows | `audio` | `sub`, `dub` (`:1328`, `:1345`, `:1407`) |
| Kiwi downloads | `downloads[audio]` keyed by `sub`/`dub` (`:1131`) |
| AnimeHeaven | none | one MP4 per episode, audio not labelled by the provider |

So a server row is `sub` unless the provider says otherwise, `raw` is a distinct
case that must not be shown as either, and a provider that publishes no audio
label (AnimeHeaven) must not be guessed at.

The watch page already prints the honest result of this: "English subtitles" and
"Provider-listed English dub" headings, and a footnote saying quality and dub
availability are read from the provider for that exact episode.

## Proposed model

```python
{
  "id": "anikoto-camstream-hd-1-sub",   # existing server id, unchanged
  "name": "CamStream HD-1 (SUB)",       # existing label, unchanged
  "audio": "sub",                       # "sub" | "dub" | "unknown"
  "label": "English subtitles",         # display copy, derived from audio
  "quality": "1080p",                   # existing height badge, may be None
  "kind": "direct" | "hls" | "iframe",  # existing transport, unchanged
  "url": "...",
  "referer": "...",
}
```

`audio` is the only new field. `unknown` is deliberate: it means "the provider did
not publish a label", which is different from `sub` (the provider said subtitles)
and must never be rendered as a claim.

The episode-level summary the UI needs:

```python
{
  "episode": {"anime_id": 21, "ep_num": 1},
  "tracks": {"sub": True, "dub": False, "unknown": True},
  "servers": [...],           # the list above, grouped by audio in the UI
  "preferred": "sub",         # what the player should try first
}
```

## Fallback behaviour

Selection order, applied in the player, not the provider:

1. The audio the viewer last chose for this anime (`camanime_audio_<anime_id>` in
   localStorage), when a server with that audio exists for this episode.
2. Otherwise the site default, `sub`, when a `sub` server exists.
3. Otherwise `dub`, when only dub exists (the common case for a dub-only release).
4. Otherwise `unknown` servers, presented without an audio claim.
5. Otherwise the existing "no provider source resolved" state, which already
   offers the next server and the episode's other servers.

Rules that fall out of the provider behaviour:

- Never relabel: if the provider says `dub`, the button says dub even when the
  viewer's preference is sub. The preference reorders, it does not rename.
- Never invent a track: `unknown` sources are never counted in "English
  subtitles" or "English dub" headings, and an episode with only `unknown`
  sources shows the footnote, not a track heading.
- Switching audio switches server, and the position is preserved: the new server
  starts at the current `currentTime` when it is within 5 seconds of a valid
  resume point, using the same resume key the player already writes.
- A failed switch falls through the list rather than stopping: the existing
  `autoTryNextServer` path is the mechanism, with audio-filtered candidates.

## What the API returns

No breaking change. `audio` is additive on each server object; clients that
ignore it keep working. `/api/v1/stream` and the watch page both already carry a
server list, so the field lands on the same objects in both.

Where the provider gives no label, the field is `unknown` rather than absent, so
clients can distinguish "not labelled" from "old response without the field".

## Tests this design needs

1. A provider fixture that returns a `dub` server keeps `audio == "dub"` through
   the resolver, and the label copy matches.
2. An AnimeHeaven episode with one MP4 yields `audio == "unknown"` and no track
   heading in the rendered watch page.
3. Preference storage: `sub` chosen, then an episode that only has dub resolves
   to the dub server without rewriting its label.
4. Switching audio mid-episode keeps the position within the resume tolerance.
5. The existing dub assertions in `tests/test_catalog_api.py` keep passing
   unchanged, proving the additive field breaks no copy.

## Why this is not implemented yet

The field is trivial; the risk is in the copy. The watch page currently states
dub availability only where the provider publishes it, and the six parity checks
that guard both hosts compare rendered asset lists, not track claims. Adding the
field without the UI grouping would put two headings on screen with one server
list behind them, which reads as a claim the providers do not make. It should
land together with the player's audio switch and its tests, in one change.
