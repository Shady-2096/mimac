# Phase 4 — Historical Storage

Phase 4 uses raw SQLite rather than GRDB. The database is owned exclusively by `mimacd`, runs in
WAL mode with `synchronous=NORMAL`, and is never opened by the SwiftUI app. All consumers query it
through the versioned XPC surface.

## Storage location and schema

Development database:

```text
~/Library/Application Support/Mimac/history.sqlite
```

Tiers and retention:

- `samples_raw` / `system_samples`: adaptive-rate observations, approximately 2 hours.
- `minutes` / `system_minutes`: one-minute rollups, 7 days.
- `hours` / `system_hours`: hourly rollups, 90 days.
- `days` / `system_days`: local-calendar daily rollups, retained unless the hard cap requires a
  future policy change.
- `entities`: stable identity registry with first/last seen timestamps.
- `events`: sample gaps, power-source transitions, and sampled entity start/stop transitions.

Rollups use `INSERT OR REPLACE` over complete buckets, so rerunning an interrupted job is
idempotent. Retention runs after rollup, ensuring raw data is not removed before its minute tier is
materialized. A 200 MB hard cap trims older high-resolution tiers first and uses incremental vacuum
plus WAL checkpoints.

The current collector derives reset-safe interval deltas using `(pid, processStartTime)` before
persistence. Phase 4 stores those deltas rather than re-storing the original process counters; a
new/restarted process contributes only after its new baseline exists, preventing counter-reset
spikes. Energy remains joules end-to-end.

## Query surface

Inspect the store:

```sh
.build/release/mimacctl history health
```

Top entities over the last hour:

```sh
.build/release/mimacctl history top energyJoules --hours 1 --limit 10
.build/release/mimacctl history top cpuSeconds --hours 1 --limit 10
```

Entity and system timelines:

```sh
.build/release/mimacctl history entity <entity-id> --hours 1 --resolution raw
.build/release/mimacctl history system --hours 24 --resolution automatic
```

Automatic resolution selects raw for ≤2 hours, minute for ≤7 days, hour for ≤90 days, and day
beyond that. Explicit resolutions are `raw`, `minute`, `hour`, `day`, and `automatic`.

## Verification completed

- SQLite persistence, entity/system queries, top-N ranking, and event capture.
- Idempotent re-rollup produces unchanged totals.
- Raw retention occurs after minute rollup creation.
- Live launchd collector created and queried the WAL database successfully.
- Fresh past-hour and past-24-hour XPC queries completed below the CLI timer's 10 ms resolution.

## Remaining acceptance work

- Seven uninterrupted days on the development machine.
- Verify database fill rate and hard-cap behavior with the real entity count.
- Compare minute/hour/day aggregates against raw sums after enough wall time has elapsed.
- Confirm past-hour and past-24-hour queries remain below 100 ms at mature database size.
- Re-measure daemon overhead with persistence enabled across visible, active, and idle sampling.
