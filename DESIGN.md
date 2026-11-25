---
name: Mimac
description: A bench instrument for reading what your Mac is costing you
colors:
  panel: "#101315"
  panel-raised: "#171B1E"
  well: "#0A0C0E"
  hairline: "#2A3135"
  graticule: "#20272B"
  graticule-major: "#2E373C"
  ink: "#E6EBED"
  ink-dim: "#A8B2B7"
  ink-faint: "#7C868B"
  ch1: "#E8B93C"
  ch2: "#4FC3D9"
  ch3: "#D96BA8"
  ch4: "#7FBF6A"
  ch5: "#9B8BD9"
  ch6: "#E08A4C"
  caution: "#E2A03F"
  alarm: "#E05C4E"
  nominal: "#6FA88F"
typography:
  readout:
    fontFamily: "SF Mono, ui-monospace, monospace"
    fontSize: "46px"
    fontWeight: 500
    lineHeight: 1
    letterSpacing: "-0.01em"
  figure:
    fontFamily: "SF Mono, ui-monospace, monospace"
    fontSize: "11.5px"
    fontWeight: 400
    lineHeight: 1.2
    letterSpacing: "normal"
  legend:
    fontFamily: "SF Compact Text, -apple-system, sans-serif"
    fontSize: "9.5px"
    fontWeight: 600
    lineHeight: 1
    letterSpacing: "0.09em"
  entity:
    fontFamily: "SF Pro Text, -apple-system, sans-serif"
    fontSize: "13px"
    fontWeight: 500
    lineHeight: 1.25
    letterSpacing: "normal"
rounded:
  none: "0px"
  control: "2px"
spacing:
  hair: "1px"
  tight: "4px"
  div: "8px"
  block: "16px"
  region: "24px"
components:
  button-segment:
    backgroundColor: "{colors.panel}"
    textColor: "{colors.ink-dim}"
    typography: "{typography.legend}"
    rounded: "{rounded.control}"
    padding: "5px 12px"
  button-segment-active:
    backgroundColor: "{colors.panel-raised}"
    textColor: "{colors.ink}"
  channel-row:
    backgroundColor: "{colors.panel}"
    textColor: "{colors.ink}"
    typography: "{typography.entity}"
    rounded: "{rounded.none}"
    padding: "9px 16px"
---

# Design

## Overview

Mimac is dressed as a **bench oscilloscope** — a digital storage scope or logic analyzer, the
instrument whose entire job is showing a measured quantity honestly over time. The world was chosen
because its grammar maps onto the product with almost no translation: channels are entities, the
time base is the window selector, the record buffer is history, and a **solid trace versus a ghosted
trace** is how instruments have always separated a live measurement from a reconstruction. That last
one carries the product's hardest rule (measured and estimated must be visually distinguishable
everywhere) in the world's own material rather than in a legend.

What this world refuses: the **gauge farm** — circular dials, sensor names, sparkline soup, one neon
accent glowing on pure black. That is the iStat/Sensei axis, which Mimac deliberately avoids. A scope is
traces, channels, and a graticule; it competes on fidelity, not on ornament. It equally refuses the
opposite default — the friendly consumer dashboard of rounded cards, gradient icon tiles, and a
single warm accent, which is what the previous design drifted into.

Physical scene that forces the appearance: a developer at a MacBook at night, dark IDE, external
display, glancing over while a build runs. Low emission, no glare, nothing that blooms.

**Register, set by the user 2026-08-06 — calm, not costume.** The instrument world supplies the
discipline, not a theme to cosplay. Keep what makes the screen fast and honest: monospaced tabular
figures, hairline division, functional channel colour, solid-versus-hatched encoding, flat surfaces.
Drop the theatrics: no CRT bezels or wells dressed as hardware, no acquisition jargon, no graticule
where a chart does not need one, and uppercase tracked legends used sparingly rather than on every
label. The brief is "a calm, informative, understandable and useful alternative to Activity Monitor"
— when literal instrument fidelity and calm legibility conflict, calm wins.

## Colors

Strategy: **neutral instrument ground plus a functional channel palette.** No colour in this system
is decorative. A colour either identifies a channel, states an instrument condition, or is ink.

### Primary

The channel palette follows the canonical DSO channel order (yellow, cyan, magenta, green — the
order every scope user already reads), extended to six for the top consumers. A channel colour is
**identity, assigned stably to an entity**, never a severity.

`ch1 #E8B93C` · `ch2 #4FC3D9` · `ch3 #D96BA8` · `ch4 #7FBF6A` · `ch5 #9B8BD9` · `ch6 #E08A4C`

Entities beyond the top six render in `ink-dim` with no channel rule. Colour is earned by mattering.

### Secondary

Instrument conditions, kept deliberately off the channel register so a condition can never be
mistaken for an identity: `nominal #6FA88F` · `caution #E2A03F` · `alarm #E05C4E`.

Condition is **never carried by colour alone** — it also moves a limit marker on the graticule and
changes the condition label's text. A colourblind user reads the same state.

### Neutral

`well #0A0C0E` (recessed trace field) · `panel #101315` (chassis) · `panel-raised #171B1E` (active
control, header) · `hairline #2A3135` · `graticule #20272B` · `graticule-major #2E373C` ·
`ink #E6EBED` (16.4:1) · `ink-dim #A8B2B7` (8.7:1) · `ink-faint #7C868B` (5.0:1). Every ink clears
4.5:1 on `panel`; `ink-faint` is the floor and is never used below 9.5px.

The chassis is a warm-neutral graphite, **not pure black**, and the trace well is darker than the
chassis. That value step is what makes the surface read as a physical instrument.

### Named Rules

- **Never emit a glow, bloom, or coloured shadow.** Traces are crisp 1px. A glowing edge is the
  single fastest way to turn this world into the cliché it was chosen against.
- **No gradients**, except one permitted use: the vertical falloff under a filled area trace, at
  ≤18% alpha of its channel colour.
- Amber (`ch1`) is a channel, not a brand accent. It must never be applied to a control, a border, or
  a heading simply for warmth.

## Typography

Three faces, each doing one job, all shipped with macOS.

- **SF Mono** — every number, without exception, with tabular figures. Columns of figures must align
  on the decimal; this is what makes the table scannable faster than Activity Monitor.
- **SF Compact Text** — legends and labels only: uppercase, semibold, `0.09em` tracking, 9.5px. These
  are instrument silkscreen legends, and they are always small.
- **SF Pro Text** — entity names and prose. The one place proportional type is allowed.

**SF Rounded is banned from this app.** It was the previous design's voice and it is the opposite of
instrument-grade.

### Hierarchy

| Role | Face | Size / weight |
|---|---|---|
| Primary readout | SF Mono | 46 / medium, tabular, -0.01em |
| Secondary readout | SF Mono | 22 / medium, tabular |
| Unit (beside readout) | SF Compact | 11 / semibold, tracked, `ink-dim` |
| Legend | SF Compact | 9.5 / semibold, uppercase, 0.09em, `ink-faint` |
| Table figure | SF Mono | 11.5 / regular, tabular |
| Entity name | SF Pro Text | 13 / medium |
| Entity sub-line | SF Pro Text | 10.5 / regular, `ink-dim` |

## Layout

**The graticule is the grid.** The trace field is ruled 10 divisions across by 8 down, the scope
standard; minor divisions subdivide by 5. Layout spacing derives from the division: 8pt base, 16pt
between blocks, 24pt between regions, 4pt inside a control.

Panels are rectangular regions separated by 1px hairlines. There are no floating cards and no
margins-around-everything; regions meet at rules, the way an instrument face is divided. The window
is one continuous instrument face, edge to edge.

## Elevation & Depth

Depth is **material value plus a hairline**, never a shadow.

- Recessed (trace well): darker than chassis, 1px `hairline` border, plus a 1px top inner edge one
  step lighter — a recessed screen catches light on its upper bezel.
- Raised (active control, header bar): `panel-raised`, 1px `hairline`.
- **Drop shadows, blurs, and glassmorphism are banned.** Real instruments are flat.

## Shapes

Radius is effectively zero. Panels, wells, rows, bars and traces are square. Interactive controls may
take `2px` — the radius of a moulded instrument key — and nothing in the app exceeds it. Circles
appear only where the referent is genuinely circular; there are no pill shapes.

## Components

### Buttons

Segmented instrument keys: square-ish (`2px`), hairline-bordered, legend type. Inactive is `panel`
with `ink-dim`; active fills `panel-raised` with `ink` and gains a 1px top highlight. No pills, no
filled accent buttons. A destructive or committing action is the only place `alarm` may fill.

### Chips

Condition labels: uppercase legend type inside a 1px border, no fill at nominal. Caution and alarm
fill at 12% of their colour and take a matching border. Always paired with a word, never colour-only.

### Cards / Containers

There are no cards. Content lives in **panels** — full-bleed rectangular regions divided by hairlines
— and in **wells**, the recessed fields that hold traces.

### Inputs / Fields

Fields are recessed: `well` background, 1px `hairline`, `2px` radius, SF Pro Text. Focus raises the
border to `ink-dim` and adds a 1px inner top edge. No focus glow.

### Navigation

The two surfaces (Live, Battery) are a segmented instrument key group in the header bar, not tabs
with an underline and not pills.

### Channel Row — signature component

The product's workhorse, replacing the old icon-tile row. Left to right: the real app icon at 16px
with no container, the entity name over its sub-line, then right-aligned SF Mono figures on a fixed
column grid. Hover adds a faint row wash. Expanding reveals raw processes in the same grammar one
level dimmer.

**Channel colour attaches to the data, never to the container.** It appears in the row's sparkline
and cost bar — the marks that carry meaning — and nowhere else. There is no coloured rule, stripe, or
border down the edge of a row or panel: that device is the previous design's discredited accent strip
wearing a new colour, and a coloured edge above 1px is decoration pretending to be structure.

### Cost Bar — signature component

Carries the measurement-honesty thesis, inherited from the previous design and restated in this
world's material: a flat horizontal bar in the entity's channel colour where the **measured** portion
is solid and the **estimated** portion is 45° 1px hatching at the same hue. Hatching is the
engineering-drawing convention for "inferred region", which is precisely what an estimate is. No
gradient, no rounded cap, no glow.

## What the first build settled

Implemented in `Sources/MimacApp/Theme.swift` as `Theme` (all colours adaptive via
`Color(light:dark:)`; the values in the frontmatter are the dark rendition).

- Type resolves to three system faces, no custom bundling: `Theme.figure()` (SF Mono, tabular) for
  every number, `Theme.entity()` (SF Pro Text) for names and prose, and `Eyebrow` (9.5px semibold,
  0.85 tracking) for legends. `design: .rounded` appears nowhere in the app.
- Components that survived: `Hairline`, `Well`, `Eyebrow`, `Sparkline`, `Graticule`, `EnergyBar`,
  `PillPicker`, `ConfidenceBadge`, `StatusDot`, and the two button styles.
- Two layout traps found in the build and worth remembering: a `Hairline(axis: .vertical)` inside an
  otherwise unbounded `HStack` stretches to fill its parent, so segmented controls need both a fixed
  divider height and `.fixedSize()`; and `Sparkline` scales to `peak * 1.18` so a steady reading
  draws inside the field instead of pinned to its ceiling.
- Units live in the column head or beside the readout, never inside the cell, so `Format.percent`,
  `Format.watts` and `Format.celsius` all return bare numbers.

## Do's and Don'ts

**Do**

- Put every number in SF Mono with tabular figures, aligned in a fixed column grid.
- Divide regions with 1px hairlines that run edge to edge.
- Let the graticule show through behind traces; it is structure, not decoration.
- State units in a separate small legend beside the figure, never inside it.
- Say "not available" where macOS exposes nothing, in `ink-faint`, and never draw an empty chart.

**Don't**

- No rounded corners beyond 2px, no pills, no SF Rounded.
- No drop shadows, glows, blurs, or glassmorphism.
- No gradient icon tiles, no decorative accent bars or strips along a container edge.
- No circular gauges, dials, donuts, or sensor-name grids — that is the category this app refuses.
- No colour-only state. No fabricated precision (`5.2%`, never `5.237%`).
