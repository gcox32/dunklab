# Dunk Lab design

Subject: one athlete closing the gap between their best touch and a dunk.
Audience: that athlete, mid-session, often sweaty and out of breath.
Primary job: show how far away the next dunk on the athlete's ladder is and what to do today to close it.

## The memorable thing

A Vertec. The jump tester's stack of colored vanes is the most specific object in
this world, and it's literally a measurement of the thing we care about. The home
screen draws the top of one, from just below the rim to above the goal dunk. Vanes below
your best touch are swept aside, like after a real jump. The vanes still standing
between your touch and the dunk line are the gap. Everything else stays quiet.

## Tokens

Color (light / dark)
- Backboard `#F3F5F6` / `#0F1A23`: page. Cool glass white, not cream.
- Glass `#FFFFFF` / `#172430`: raised surfaces.
- Ink `#16222D` / `#E8EDF1`: text. Navy slate, not tinted black.
- Chalk `#D3D9DF` / `#2A3947`: hairlines, half-inch vanes.
- Vane blue `#2457A8` / `#5B8DE0`: inch vanes, progress, primary actions.
- Vane red `#C7302A` / `#E5524B`: six-inch vanes and the dunk line only.
- Rim orange `#E0661C` / `#F07A2E`: the rim line, nothing else.

Type
- Readouts and titles: SF Pro Compressed, heavy. Measurements are the content,
  and compressed numerals stack like the tape on a Vertec pole.
- Everything else: SF Pro Text, default sizes for Dynamic Type.
- Lengths use primes, not quotes: 10′ 4½″. Fractions are glyphs (½ ¼ ¾).

Layout
- Left-aligned throughout. Native grouped lists for anything you scroll and edit.
  No card grids.
- Today: the ladder fills the top, with the gap as a full sentence above it.
  Next workout and this week's play budget follow as plain rows.
- Live practice: built for thumbs. Three big outcome buttons in the bottom half,
  with the focus cue always visible at the top.

```
 Two-hand dunk
 Your best touch is 5″ short of it.
 ┃▬▬▬▬ · · · ·    10′ 10″ next dunk
 ┃▬▬▬▬▬ ─ ─ ─ ─   10′ 9″  goal dunk
 ┃▬▬
 ┃▬▬▬▬
 ┃▪ ───────────   10′ 4″  best touch
 ┃▪
 ┃▪ ━━━━━━━━━━━   10′     rim
 ┃▪
 Standing reach 7′ 10½″, so that touch is a 29½″ vertical.
```

Principles
- Inches are the unit of progress. Every screen answers "did the gap move?"
- Practice with purpose: name the focus before the first attempt, and cap the
  attempts. Fatigued jumps train slow jumps.
- Program content is data the athlete can edit, never code.

## Review against generic defaults

- Not a cream page with a serif display, and not near-black with one acid accent.
  The palette comes from the Vertec and the backboard, and red and orange are
  each held to one meaning.
- Considered a big gap number with a small label and rejected it as the default
  treatment. The gap is a sentence above the ladder, and the ladder carries the
  visual weight.
- No all-caps eyebrows, no middle-dot meta strings, no arrows on buttons, no
  monospace labels.
- One orchestrated motion: vanes sweep up to your best touch when Today
  appears. It's skipped when Reduce Motion is on.
