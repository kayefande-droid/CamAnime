import io, re, sys

MAP = {
    "#ffb347": "var(--accent)",
    "#0e111a": "var(--bg-elevated)",
    "#141926": "var(--bg-input)",
    "#f3f5fa": "var(--text)",
    "#a0abc0": "var(--text-secondary)",
    "#64708a": "var(--text-muted)",
    "#07080d": "var(--bg)",
    "#0a0c14": "var(--accent-ink)",
}
COLOR = re.compile(r"#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6})\b")
DEFN = re.compile(r":root|data-theme")


def scan(text):
    """Split CSS into parts. Each part is a str (copied verbatim) or ("arg", str)
    meaning a declaration run outside a token-definition block."""
    parts, sels, stack, attr, i, n = [], [], [], [], 0, len(text)
    while i < n:
        if text[i:i + 2] == "/*":
            j = text.find("*/", i + 2)
            j = n if j < 0 else j + 2
            attr.append(text[i:j])
            i = j
            continue
        ch = text[i]
        if ch == "{":
            sel = "".join(attr).strip()
            parts.append("".join(attr))
            attr = []
            parts.append("{")
            sels.append(sel)
            stack.append(bool(DEFN.search(sel)))
            i += 1
            continue
        if ch == "}":
            parts.append("".join(attr))
            attr = []
            parts.append("}")
            if not stack:
                raise SystemExit("unbalanced }")
            stack.pop()
            i += 1
            continue
        attr.append(ch)
        if ch == ";":
            run = "".join(attr)
            attr = []
            parts.append(run if any(stack) else ("arg", run))
        i += 1
    parts.append("".join(attr))
    if stack:
        raise SystemExit("unbalanced {")
    return parts, sels


def fix(run):
    for lit, tok in MAP.items():
        name = tok[4:-1]
        run = re.sub(r"var\(" + re.escape(name) + r",\s*" + re.escape(lit) + r"\s*\)",
                     tok, run, flags=re.I)
    return COLOR.sub(lambda m: MAP.get(m.group(0).lower(), m.group(0)), run)


def convert(path):
    src = io.open(path, encoding="utf-8", newline="").read()
    parts, sels = scan(src)
    out, count = [], 0
    for part in parts:
        if isinstance(part, tuple):
            body = part[1]
            count += sum(1 for m in COLOR.findall(body) if m.lower() in MAP)
            new = fix(body)
            if new.count("{") != body.count("{") or new.count("}") != body.count("}"):
                raise SystemExit(path + ": structure changed inside a declaration")
            out.append(new)
        else:
            out.append(part)
    new_text = "".join(out)
    if scan(new_text)[1] != sels:
        raise SystemExit(path + ": selector sequence changed, not written")
    if new_text.count("{") != src.count("{") or new_text.count("}") != src.count("}"):
        raise SystemExit(path + ": brace count changed, not written")
    io.open(path, "w", encoding="utf-8", newline="").write(new_text)
    return count


for p in sys.argv[1:]:
    print(p, "colour literals replaced:", convert(p))
