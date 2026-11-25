# Stage 1 — Telemetry Collector

Stage 1 keeps the project headless. It adds:

- `mimacd`: an adaptive sampling daemon with a launchd Mach service.
- `mimacctl`: a JSON CLI over XPC (`snapshot`, `health`, and UI visibility hints).
- Self-reporting CPU and resident-memory overhead in every sample.
- Per-metric failure isolation: battery/process failures are recorded in `errors` without stopping the daemon.

## Local smoke test

```sh
swift build
.build/debug/mimacd --stdio --once
```

The first snapshot establishes monotonic baselines. Run without `--once` to see useful process deltas from subsequent samples.

## LaunchAgent installation (development)

Build release binaries and install a user-specific plist:

```sh
swift build -c release
mkdir -p "$HOME/Library/LaunchAgents"
sed "s|__MIMACD_PATH__|$PWD/.build/release/mimacd|g" \
  LaunchAgents/com.mimac.collector.plist \
  > "$HOME/Library/LaunchAgents/com.mimac.collector.plist"
launchctl bootout "gui/$UID/com.mimac.collector" 2>/dev/null || true
launchctl bootstrap "gui/$UID" "$HOME/Library/LaunchAgents/com.mimac.collector.plist"
```

Then inspect it:

```sh
.build/release/mimacctl health
.build/release/mimacctl snapshot
.build/release/mimacctl watch
```

Snapshots now include `entities` and `workloads` alongside the raw `processes` expansion rows.
Identity corrections are available before the SwiftUI screen lands:

```sh
.build/release/mimacctl rules list
.build/release/mimacctl rules save commandPattern '*vite*' 'Vite dev server' devServer
.build/release/mimacctl rules delete <rule-id>
```

`watch` holds an XPC session open and requests the visible sampling rate until interrupted. The future app should do the same while its Live screen is open. If a client crashes, its XPC session is invalidated and the daemon automatically drops the visibility hint. Sampling is 2 seconds while visible, 5 seconds while active, 15 seconds when idle on wall power, and 30 seconds when idle on battery.

To uninstall the development LaunchAgent:

```sh
launchctl bootout "gui/$UID/com.mimac.collector"
rm "$HOME/Library/LaunchAgents/com.mimac.collector.plist"
```

Production installation will move to the signed app's `SMAppService` flow; this plist is intentionally a development artifact.
