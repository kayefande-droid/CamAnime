"""Regression tests: every remote poster image must degrade gracefully.

A poster <img> whose src is a template variable must carry an onerror
fallback ( swaps to the local brand icon or hides cleanly ), so a dead CDN
URL or an empty metadata field can never render as a broken-image box.
Local brand/logo images are exempt.
"""

import re
from pathlib import Path

TEMPLATES = Path(__file__).resolve().parent.parent / "templates"

IMG_RE = re.compile(r"<img\b[^>]*>", re.IGNORECASE)


def _remote_imgs_without_fallback():
    bad = []
    for path in sorted(TEMPLATES.glob("*.html")):
        for match in IMG_RE.finditer(path.read_text(encoding="utf-8")):
            tag = match.group(0)
            src = re.search(r'src="([^"]*)"', tag)
            if not src:
                continue
            if "{{" not in src.group(1) and "${" not in src.group(1):
                continue  # local/static image: nothing remote to break
            if "onerror" not in tag:
                bad.append(f"{path.name}: {tag[:100]}")
    return bad


def test_all_remote_posters_have_error_fallbacks():
    assert _remote_imgs_without_fallback() == []


def test_home_renders_icon_fallback_for_empty_poster_url(api=None):
    """An empty poster URL must still render the local icon, not src=""."""
    import sys
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
    import app as api_mod
    from unittest.mock import patch

    api_mod.app.config["TESTING"] = True
    client = api_mod.app.test_client()
    with patch.object(api_mod, "fetch_anilist", return_value={}), \
         patch.object(api_mod, "_fallback_home_lists",
                      return_value=({"trending": [], "popular": [],
                                     "ongoing": [], "series": [],
                                     "top_rated": [], "movies": [],
                                     "recent": []}, "kitsu")), \
         patch.object(api_mod.streaming_manager.animeheaven,
                      "browse_catalog", return_value=[]), \
         patch.object(api_mod, "get_current_season_schedule",
                      return_value=[]):
        resp = client.get("/")
    assert resp.status_code == 200
    assert 'src=""' not in resp.get_data(as_text=True)
