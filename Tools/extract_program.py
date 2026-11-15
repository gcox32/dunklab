#!/usr/bin/env python3
"""Convert the Jump Science "PhD Program" PDF into the app's program JSON.

Usage: python3 extract_program.py <PhD Program.pdf> <out.json>

The output is seed data only: the app imports it once into its store, where
it can be edited like any user-made program.
"""
import json
from collections import Counter
import re
import subprocess
import sys

KINDS = [
    ("warmup", ["warmup"]),
    ("sprint", ["sprint", "running"]),
    ("isometric", [" iso", "isometric"]),
    ("mobility", ["stretches"]),
    ("plyometric", ["jump", "hops", "hop ", "landings", "line hops", "jumps"]),
    ("core", ["plank", "rollouts", "leg raises", "rotation"]),
]


def kind_for(name):
    n = " " + name.lower()
    for kind, needles in KINDS:
        if any(k in n for k in needles):
            return kind
    return "strength"


EFFORTS = {"light", "medium", "heavy"}


def parse_load_token(tok):
    tok = tok.strip()
    if tok in EFFORTS:
        return {"effort": tok}
    if tok == "body weight":
        return {"bodyweight": True}
    m = re.fullmatch(r"(\d+(?:\.\d+)?)%?", tok)
    if m:
        return {"percent": float(m.group(1))}
    return None


def loads_for(spec, count):
    """Expand a weight spec like '50, 55, 4 sets at 60%' into one load per set."""
    if spec is None:
        return [None] * count
    s = spec.replace(" of max deep squat", "").strip()
    # "50% to 90%", "medium to heavy", "30% up to heavy"
    m = re.fullmatch(r"(.+?)\s+(?:up\s+)?to\s+(.+)", s)
    if m:
        a, b = parse_load_token(m.group(1)), parse_load_token(m.group(2))
        if a and b and "percent" in a and "percent" in b and count > 1:
            lo, hi = a["percent"], b["percent"]
            return [
                {"percent": round((lo + (hi - lo) * i / (count - 1)) / 2.5) * 2.5}
                for i in range(count)
            ]
        if count == 1:
            return [b]
        return [a] + [a if "effort" in a else None] * (count - 2) + [b] if count > 2 else [a, b]
    parts = [p.strip() for p in s.split(",")]
    out = []
    for p in parts:
        m = re.fullmatch(r"(\d+) sets at (.+)", p)
        if m:
            out += [parse_load_token(m.group(2))] * int(m.group(1))
        else:
            out.append(parse_load_token(p))
    # A trailing % applies to every bare number in the list.
    if len(out) == count:
        return out
    if len(out) == 1:
        return out * count
    if len(out) < count:
        # The PDF sometimes lists fewer loads than sets ("8x4 (50, 60, 70,
        # 4 sets at 75%)"); hold the last load for the remaining sets.
        return out + [out[-1]] * (count - len(out))
    raise ValueError(f"cannot expand '{spec}' to {count} sets")


def parse_prescription(text):
    """Returns (sets, per_side, extra_detail)."""
    detail = []
    per_side = None
    t = text
    if m := re.search(r"\((\d+ landings each leg)\)", t):
        detail.append(m.group(1))
        t = t.replace(m.group(0), "")
    for phrase, side in [("each leg", "leg"), ("each side", "side")]:
        if phrase in t:
            per_side = side
            t = t.replace(phrase, "")
    if "alternating legs" in t:
        detail.append("alternating legs")
        t = t.replace("alternating legs", "")
    weight = None
    m = re.search(r"\(([^)]*)\)", t)
    if m:
        inner = m.group(1)
        if inner == "heavy on the descent":
            weight, extra = "heavy", "heavy on the descent"
            detail.append(extra)
        elif inner.startswith("2 landings"):
            detail.append(inner)
        else:
            weight = inner
        t = t[: m.start()] + t[m.end():]
    m = re.search(r"from (~?\d+cm)", t)
    if m:
        detail.append(f"from {m.group(1)}")
        t = t.replace(m.group(0), "")
    t = t.strip()

    sets = []
    if m := re.fullmatch(r"(\d+)x(\d+)", t):
        n, reps = int(m.group(1)), int(m.group(2))
        sets = [{"reps": reps} for _ in range(n)]
    elif m := re.fullmatch(r"(\d+) seconds x(\d+)", t):
        secs, n = int(m.group(1)), int(m.group(2))
        sets = [{"seconds": secs} for _ in range(n)]
    elif m := re.fullmatch(r"(\d+) rounds?", t):
        sets = [{} for _ in range(int(m.group(1)))]
        detail.insert(0, "round")
    elif re.fullmatch(r"(\d+m x\d+)(, \d+m x\d+)*", t):
        for dist, n in re.findall(r"(\d+)m x(\d+)", t):
            sets += [{"meters": int(dist)} for _ in range(int(n))]
    elif t == "as needed":
        pass
    else:
        raise ValueError(f"unparsed prescription '{text}'")
    for s, load in zip(sets, loads_for(weight, len(sets)) if sets else []):
        if load:
            s["load"] = load
    if not sets and weight:
        raise ValueError(f"weight with no sets '{text}'")
    return sets, per_side, detail


PRESCRIPTION = re.compile(
    r"\d+x\d+.*|\d+ seconds x\d+.*|\d+m x\d+.*|\d+ rounds?.*|as needed.*|see video.*"
)


def parse_item(line):
    cols = [c.strip() for c in re.split(r"\s{2,}", line.strip()) if c.strip()]
    name = cols[0]
    rest = cols[1:]
    if not rest:
        # Some rows have a single space before the prescription.
        m = re.search(r"\s(\d+x\d+|\d+ seconds x\d+|\d+m x\d+|\d+ rounds?)\b", name)
        if m:
            rest = [name[m.start():].strip()]
            name = name[: m.start()].strip()
    item = {"exercise": name, "kind": kind_for(name), "sets": []}
    text = rest[0] if rest else ""
    details = rest[1:]
    if text.startswith("see video"):
        # The app shows the linked video instead.
        rest_of_note = text[len("see video"):].strip(" ;,")
        details = ([rest_of_note] if rest_of_note else []) + details
        text = ""
    elif text and not PRESCRIPTION.fullmatch(text):
        raise ValueError(f"unexpected row '{line}'")
    if text:
        # Trailing prose after the parenthesized weight belongs in details.
        m = re.match(r"(.*?\))\s+(\D.*)$", text)
        if m and "(" in m.group(1):
            text, details = m.group(1), [m.group(2)] + details
        m = re.match(r"((?:\d+m x\d+,? ?)+)\s+(rest.*)$", text)
        if m:
            text, details = m.group(1).strip(), [m.group(2)] + details
        sets, per_side, extra = parse_prescription(text)
        item["sets"] = sets
        if per_side:
            item["perSide"] = per_side
        details = extra + details
        item["prescription"] = text
    if details:
        item["details"] = "; ".join(details)
    return item


# The PDF states the decision branches as prose; these make them actionable.
DECISION_OPTIONS = {
    10: [
        {"label": "Keep the gains rolling", "detail": "Stronger and jumping higher. Go back to week 5.", "goToWeek": 5},
        {"label": "Shift to explosive", "detail": "Stronger, but jumping is lagging. Move on to weeks 11 to 16.", "goToWeek": 11},
        {"label": "Get fresh, then restart", "detail": "Neither improved. Take a couple of easy weeks, check nutrition, sleep and stress, then restart at week 1.", "goToWeek": 1},
    ],
    16: [
        {"label": "Repeat the explosive shift", "detail": "Jumping kept climbing. Repeat some or all of weeks 11 to 16.", "goToWeek": 11},
        {"label": "Back to strength", "detail": "Jumping stalled or dropped. Restart the program at week 1.", "goToWeek": 1},
    ],
}


# Videos the PDF asks you to watch before testing the max deep squat.
BASIS_VIDEOS = ["Squat Mechanics", "Deep Squats", "Max Squat Test"]

# From "PhD Olympic Lifting": clean pulls can be replaced with any lift that has
# a power catch (above parallel), done as single reps building to heavy.
SWAPS = [
    {
        "replaces": "clean pulls",
        "options": ["power clean", "power snatch", "push jerk", "split jerk"],
        "sets": [{"reps": 1, "load": {"effort": e}}
                 for e in ["light"] * 3 + ["medium"] * 4 + ["heavy"] * 3],
        "details": "single reps, light building to heavy; go heavy enough to feel how strong you are",
    }
]


def gauge_for(item):
    """How an item reads the athlete: a max test, the feel of the bar, or RSI."""
    if "chance to max out" in item.get("details", ""):
        return "maxTest"
    if item["exercise"] == "clean pulls":
        return "barSpeed"
    if item["exercise"] == "drop jumps":
        return "reactive"
    return None


def pdf_links(pdf):
    """(link text, URL) pairs in page order, from the PDF's link annotations.

    pdftotext drops links, so read them from pdftohtml's XML.
    """
    xml = subprocess.run(
        ["pdftohtml", "-xml", "-i", "-stdout", pdf], capture_output=True, text=True, check=True
    ).stdout
    return [(re.sub(r"<[^>]+>", "", text).strip(), href)
            for href, text in re.findall(r'<a href="([^"]+)">(.*?)</a>', xml)]


def assign_videos(links, groups):
    """Gives each item in `groups` its video.

    When every chart row of a name is linked, rows take their own links in
    order, so a variation with its own video keeps it. Otherwise a name takes
    the video the charts use most.
    """
    by_name = {}
    for text, href in links:
        by_name.setdefault(text.lower(), []).append(href)
    items = {}
    for group in groups:
        for item in group["items"]:
            items.setdefault(item["exercise"].lower(), []).append(item)
    for name, rows in items.items():
        hrefs = by_name.get(name, [])
        if not hrefs:
            continue
        if len(hrefs) == len(rows):
            for item, href in zip(rows, hrefs):
                item["video"] = href
        else:
            common = Counter(hrefs).most_common(1)[0][0]
            for item in rows:
                item["video"] = common


def main(pdf, out):
    raw = subprocess.run(
        ["pdftotext", "-layout", pdf, "-"], capture_output=True, text=True, check=True
    ).stdout
    lines = [l.rstrip() for l in raw.splitlines()]

    start = next(i for i, l in enumerate(lines) if l.strip() == "PhD - Week 1")
    guide_lines = [l.strip() for l in lines[:start]]

    weeks, as_needed = [], []
    week = day = group = None
    section = None  # "days" | "iso" | "stretch" | "decision"
    for line in lines[start:]:
        s = line.strip()
        if not s or s.startswith("Exercise ") or s.startswith("\f"):
            if s.startswith("\fPhD - Week") or s.startswith("\fDecision"):
                s = s[1:]
            else:
                continue
        if m := re.fullmatch(r"PhD - Week (\d+)", s):
            week = {"number": int(m.group(1)), "days": []}
            weeks.append(week)
            section = "days"
            continue
        if s == "Decision Time!":
            section = "decision"
            week["decision"] = []
            continue
        if section == "decision":
            if s.startswith("•"):
                week["decision"].append(s[1:].strip())
            else:
                week["decision"][-1] += " " + s
            continue
        if m := re.fullmatch(r"Day (\d+)", s):
            # "Give you a day of rest before the first three workouts (example:
            # MWF for three workouts or MWFSat for four)."
            n = int(m.group(1))
            day = {"title": f"Day {n}", "restDaysBefore": 1 if n <= 3 else 0, "items": []}
            week["days"].append(day)
            continue
        if s.startswith("Isometrics"):
            section, group = "iso", None
            continue
        if s == "Daily Stretches":
            section, group = "stretch", None
            if week["number"] == 1:
                group = {"title": "Daily stretches", "items": []}
                as_needed.append(group)
            continue
        if section == "iso":
            if not re.search(r"\d+ seconds", s):
                if week["number"] == 1:
                    group = {"title": s[0] + s[1:].lower().replace("it band", "IT band") if not s.startswith("IT") else "IT band" + s[7:].lower(), "items": []}
                    as_needed.append(group)
                continue
        if section in ("iso", "stretch"):
            if week["number"] == 1:
                group["items"].append(parse_item(line))
            continue
        day["items"].append(parse_item(line))

    links = pdf_links(pdf)
    # The intro links come first and their titles also name exercises, so
    # keep them out of the chart rows.
    intro = len(BASIS_VIDEOS)
    assert [t for t, _ in links[:intro]] == BASIS_VIDEOS, links[:intro]
    basis_videos = [{"title": t, "video": h} for t, h in links[:intro]]
    assign_videos(links[intro:], [d for w in weeks for d in w["days"]] + as_needed)
    for w in weeks:
        for d in w["days"]:
            for item in d["items"]:
                if gauge := gauge_for(item):
                    item["gauge"] = gauge

    for w in weeks:
        if "decision" in w:
            w["decision"] = "\n\n".join(w["decision"])
            w["decisionOptions"] = DECISION_OPTIONS[w["number"]]

    def bullets(after, until):
        i = guide_lines.index(after) + 1
        out = []
        for l in guide_lines[i:]:
            if l == until:
                break
            if not l:
                continue
            if l.startswith("•"):
                out.append(l[1:].strip())
            elif out:
                out[-1] += " " + l
        return out

    program = {
        "name": "PhD Program",
        "author": "Jump Science (Coach Daniel Back)",
        "summary": (
            "For athletes who are decently strong and already jump well. Builds "
            "max strength, then shifts back toward explosive and elastic ability."
        ),
        "percentBasis": "max deep squat",
        "basisVideos": basis_videos,
        "swaps": SWAPS,
        "guidelines": bullets("Notes about the workout charts", "THERAPEUTIC ISOMETRICS"),
        "weeks": weeks,
        "asNeeded": as_needed,
    }
    with open(out, "w") as f:
        json.dump(program, f, indent=1, ensure_ascii=False)
        f.write("\n")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
