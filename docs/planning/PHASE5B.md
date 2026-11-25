# Phase 5b — Extended Battery History (7 / 30 days)

Phase 5b extends battery attribution from the 7-day minute tier to hourly and daily tiers, adds
7-day and 30-day ranges to every query surface, and hardens rollup/retention correctness.

## Storage

Schema migration version 4 adds four tables:

- `battery_windows_hours` / `battery_windows_days` — per-bucket attributed/excluded seconds, total
  joules, raw measured joules, precomputed battery percent (so aged capacity is honored per
  window, not averaged), and a representative excluded reason.
- `battery_attribution_hours` / `battery_attribution_days` — per-bucket per-item rows preserving
  the measured/heuristic split, foreground/background split, battery percent, active seconds, peak
  watts, **worst-of confidence** (`MAX(confidence_rank)`), and cause. Bucket rows
  (Display/System/Radios/Unattributed) roll up like entities.

Both tiers roll **directly from minute windows** inside the existing `performMaintenance`
transaction. Hour buckets are UTC-aligned; day buckets use local-midnight bucketing on the window
timestamp itself, which stays exact in half-hour-offset timezones (an hour-bucket-derived day tier
would misassign up to 30 minutes around midnight in IST and similar zones).

Retention: hourly tiers follow `hourRetention` (90 d); daily tiers are kept until the 200 MB cap
evicts oldest-first. Both are wired into `enforceSizeCap`'s eviction ladder.

## Correctness hardening (applies to all tiers, not just battery)

- **Rollup lower bounds:** every rollup now re-rolls only buckets that can still receive source
  rows, plus everything after the last rolled bucket (so restarts catch up). Previously a bucket
  whose source was partially evicted could be silently replaced by a partial re-roll.
- **Entity/system day tiers** now roll from minutes instead of hours, fixing the same
  local-midnight bucketing issue.
- **Materialization resumes from the last window** instead of a fixed 2-hour lookback: minutes
  sampled just before a long sleep are attributed at the next maintenance no matter how late it
  runs, and unsampled minutes no longer flood the store with exclusion rows.

## Query surface

`batteryHistory` is resolution-aware (`minute` ≤ 48 h, `hour` ≤ 8 d, `day` beyond, when
`automatic`). Hour/day queries union the rolled tier with a **live tail** aggregated from
not-yet-rolled minute windows, so the current day/hour always appears. `BatteryHistoryReport`
now carries its resolution, and `BatteryDrainPoint` carries per-bucket joules so the UI renders
Wh bars without computing.

```sh
.build/release/mimacctl battery --days 7
.build/release/mimacctl battery --days 30 --resolution day
.build/release/mimacctl history health   # includes battery tier counts + minuteFillRatePercent24h
```

## UI

Battery History gains 1 H / 24 H / 7 D / 30 D ranges. The 7 D and 30 D views render daily Wh bars;
clicking a bar drills into that day's hourly bars and swaps the attribution table to that day, with
a CLEAR control to return. Confidence, residual bucket rows, and one-decimal percentages are
unchanged.

## Verification (2026-07-14)

- 13 unit tests pass, including: hour/day rollup totals reconciling exactly against the minute
  tier, worst-of confidence propagation, local-midnight day splitting, size-cap eviction of the
  battery tiers, and fill-rate/battery counts in storage health.
- Live daemon migrated in place; `battery --days 30` full round-trip measured at 0.22 s
  (gate: query < 500 ms).

## Remaining acceptance work

- 30 days of continuous real data on the development machine with the DB inside the 200 MB cap
  (currently ~150 MB — watch the cap once hourly attribution accumulates).
- Observe a DST shift or manual timezone change during the soak and confirm day buckets stay sane.
