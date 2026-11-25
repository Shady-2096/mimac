# Phase 3 — Live Interface

Phase 3 adds the native SwiftUI `Mimac` executable target. The app is intentionally still built by
SwiftPM for fast iteration; migration to an Xcode app bundle, signing, login-item installation, and
notarization remain Phase 7 packaging work.

## What is implemented

- Persistent XPC connection to the launchd Mach service with exponential reconnect backoff.
- Visibility hints follow the app scene lifecycle, keeping 2-second sampling only while frontmost.
- Offline state with explicit collector start and retry actions.
- Live system strip: battery watts and charge, CPU, system-wide GPU, memory pressure, disk
  throughput, network availability, thermal state, and gas-gauge time remaining.
- Power-ranked entity rows with daemon-computed activity labels and cause tooltips.
- Active project-workload rail and stable-ID row diffing.
- Expandable entity → process → raw evidence view (pid, path, args, cwd, ports, start counter,
  signing identity).
- Right-click rename flow with a suggested identity key; rules are persisted by `mimacd` and cause
  the next sample to re-resolve.
- Honest unavailable values: per-entity GPU and network stay `—` until the daemon has a defensible
  estimate/source. No UI-side attribution or aggregation is invented.

## Development run

Build the app and collector:

```sh
swift build
swift build -c release
```

Install the development LaunchAgent using the instructions in `STAGE1.md`, then launch:

```sh
.build/debug/Mimac
```

The launchd service must point at a collector built from the same source revision because the Phase
3 snapshot schema is version 3.

## Remaining acceptance work

- Run a real multi-project workflow for a full workday and confirm the Live screen replaces Activity
  Monitor in practice.
- Measure UI CPU while frontmost and hidden; require < 5% frontmost and approximately zero hidden.
- Measure UI + daemon combined overhead and confirm the daemon remains below its < 1% average CPU /
  < 100 MB RSS budget outside debug/stdio JSON encoding.
- Validate the rename flow across a daemon restart with a real correction.
- Decide whether any missing top-strip metric needs a new daemon endpoint before Phase 4 begins.
