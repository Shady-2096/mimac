# Phase 5 — Battery Attribution and Battery History

Phase 5 now has a complete production path from daemon samples to the SwiftUI Battery History
screen. Its acceptance gate remains open until the unplugged calibration matrix has been run.

## Attribution model

`mimacd` materializes wall-clock-aligned minute windows before Phase 4 raw retention runs:

- Battery energy is trapezoidally integrated from consecutive gas-gauge watt readings.
- Windows containing wall power, charging, missing gauge data, or sleep/sample gaps are excluded.
- `ri_energy_nj` deltas (falling back to `ri_billed_energy` only when unavailable) stay in the
  measured column. The final Phase 0 counter study must still confirm this choice.
- Residual energy is kept honest: Display uses brightness × screen-on time; System and Radios have
  conservative baselines; counter-less entities share only a bounded heuristic pool using P-core
  CPU at 4× E-core CPU plus disk and wakeup activity; the remainder stays Unattributed.
- Full-charge capacity comes from `AppleRawMaxCapacity × DesignVoltage`. Percentages therefore use
  aged capacity rather than design capacity or battery-level deltas.
- Every row persists High/Medium/Low confidence. Measured and heuristic joules are separate, as are
  foreground and background joules.

SQLite schema migration version 3 adds `battery_windows` and `battery_attribution`. Attribution is
retained with the seven-day minute tier for Phase 5; Phase 5b adds hourly/daily attribution tiers.

## Query and UI

```sh
.build/release/mimacctl battery --hours 1
.build/release/mimacctl battery --hours 24
```

The app's Battery History screen provides hour/24-hour ranges, drain timeline, excluded-window
markers, explicit residual buckets, one-decimal battery percentages, share of drain, and expandable
Wh / foreground / background / active duration / average and peak watts / confidence / cause.

## Calibration harness

Build once with `swift build -c release`, unplug the Mac, set a fixed brightness, then run every
matrix workload for 30–60 minutes. The harness can either wait around a manual workload or launch a
repeatable command:

```sh
.build/release/mimac-calibrate idle --minutes 30
.build/release/mimac-calibrate compile --minutes 30 --expect swift-frontend -- sh -c 'while true; do swift build -c release; done'
.build/release/mimac-calibrate agent --minutes 30 --expect Codex
```

Run labels: `idle`, `video`, `compile`, `gpu-export`, `next-churn`, `agent`, `download`, `electron`.
Each run emits machine-readable JSON with the observed dominant entity, expected-rank match,
counter gap, Unattributed percentage, drain joules, attributed duration, and reconciliation pass.
Run `powermetrics` manually alongside it when a privileged reference is wanted.

## Verification completed

- Unit coverage validates gas-gauge reconciliation, explicit residual rows, confidence propagation,
  aged-capacity percentage calculation, and Phase 4 retention/rollup compatibility.
- Full debug tests pass and every executable builds in release mode.

## Remaining acceptance work

- Complete the Phase 0 one-hour counter study and lock `energy_nj` vs billed-energy behavior.
- Run the eight 30–60 minute unplugged workloads at fixed brightness.
- Require the expected dominant consumer at rank #1 in at least 90% of runs.
- Require Unattributed/reconciliation error below 15%, then record the measured numbers here.
