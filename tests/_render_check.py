"""UI verification without network: Jinja-compile all templates + render static routes."""
import sys, glob, os
sys.stdout.reconfigure(line_buffering=True)
sys.path.insert(0, ".")
from app import app
fails = 0

# 1. Jinja syntax compile of every template
for path in sorted(glob.glob("templates/*.html")):
    name = os.path.basename(path)
    try:
        src = open(path, encoding="utf-8").read()
        app.jinja_env.from_string(src)
        src2 = src.replace("templates/", "")
        app.jinja_env.from_string(src2)
        print(f"jinja OK  {name}")
    except Exception as exc:
        # second attempt may hit UndefinedError for bare vars; syntax errors still throw TemplateSyntaxError
        from jinja2.exceptions import TemplateSyntaxError
        if isinstance(exc, TemplateSyntaxError):
            print(f"jinja FAIL {name}: {exc}"); fails += 1
        else:
            print(f"jinja OK* {name} (non-syntax: {type(exc).__name__})")

# 2. nested-var leftovers across rendered-safe templates
for path in sorted(glob.glob("templates/*.html")) + ["static/css/sync.css"]:
    src = open(path, encoding="utf-8").read()
    if 'var(--header-glass, var(' in src or 'var(--border-subtle, var(' in src or '))));' in src:
        print(f"NESTED FAIL {path}"); fails += 1

# 3. render network-free routes
client = app.test_client()
for route in ["/settings", "/login", "/owner-console", "/download", "/promo", "/scraper"]:
    resp = client.get(route)
    body = resp.get_data(as_text=True)
    has_new = all(s in body for s in ("obsidian", "neo", "tokyo"))
    ok = (resp.status_code == 200 or (route == "/owner-console" and resp.status_code == 302)) and (has_new or route == "/owner-console")
    print(f"{'PASS' if ok else 'FAIL'} {route} status={resp.status_code} themes={has_new}")
    if not ok: fails += 1
    if route == "/settings":
        for s in ('data-theme-name="obsidian"', 'data-theme-name="neo"', 'data-theme-name="tokyo"'):
            if s not in body: print(f"  missing picker button {s}"); fails += 1

with open("static/css/sync.css", encoding="utf-8") as fh:
    css = fh.read()
for tok in ('data-theme="obsidian"', 'data-theme="neo"', 'data-theme="tokyo"', 'data-data="low"', '@media (hover: hover)'):
    if tok not in css:
        print(f"sync.css missing {tok}"); fails += 1

print("RESULT:", "FAIL" if fails else "PASS")
sys.exit(1 if fails else 0)
