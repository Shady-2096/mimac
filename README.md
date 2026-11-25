# Mimac

**What's using this Mac, in watts — and what it used an hour ago.**

Mimac is a native macOS power and resource monitor for Apple Silicon. It splits the Mac's
*measured* power draw across apps, processes and hardware, so the Power column adds up to what
the machine is actually pulling, and keeps a history so you can see sustained usage instead of
a single spike.

It's built for people whose Macs run many things at once — dev servers, AI coding agents,
Docker, databases, browsers — and who want to know *which project or command* is draining the
battery.

## What it does

- **Per-app power that sums to the real draw.** Process CPU energy from the kernel, GPU time from
  the graphics driver, and the SMC power rails for the whole Mac, the chip, the CPU and the GPU.
  What no process accounts for appears as its own rows: *System processes*, *Memory & chip*, and
  *Display & rest of Mac*.
- **Grouping that matches how you think.** Processes are grouped into apps, tools (Vite, Next.js,
  Claude Code, Docker, Postgres…) and projects by working directory, with rules you can edit.
- **History.** A background collector samples continuously into a local SQLite database, with
  minute, hour and day rollups. The app shows *Now*, *10 min* and *1 h* views, plus battery drain
  and attribution over days.
- **Cheap to run.** Sampling slows from 2 s while the window is visible to 30 s when idle on
  battery.

Everything stays on your Mac. There is no network code.

## Status

Early and developer-grade. It is built and tested on one machine: an **M5 MacBook (Mac17,3) on
macOS 27**. The SMC rail mapping (which sensor keys mean whole-Mac, chip, CPU and GPU power) has
only been verified there. Other Apple Silicon Macs will run, but power figures may be missing or
wrong until their rails are mapped — see *Contributing*.

The app is ad-hoc signed and not notarized. There is no installer yet.

## Requirements

- Apple Silicon Mac, macOS 14 or later (developed on macOS 27)
- Swift 5.10 or later (Xcode or the command-line tools)

## Build and run

```sh
git clone https://github.com/Shady-2096/mimac.git
cd mimac

# 1. The collector daemon (a per-user LaunchAgent)
Scripts/install-collector.sh

# 2. The app: builds dist/Mimac.app and installs it to /Applications
Scripts/make-app.sh
open -b com.mimac.app
```

Check the collector:

```sh
.build/release/mimacctl health
.build/release/mimacctl snapshot
```

Uninstall the collector with `Scripts/install-collector.sh --uninstall`. History lives in
`~/Library/Application Support/Mimac/history.sqlite`; delete it to start over.

## Layout

| Path | What it is |
| --- | --- |
| `Sources/mimacd` | Collector daemon: sampling, power attribution, XPC service |
| `Sources/MimacHistory` | SQLite history store, rollups, battery attribution |
| `Sources/MimacIdentity` | Process → entity grouping, shared models, power split |
| `Sources/MimacCore`, `Sources/CShim` | Low-level probes (libproc, SMC, IOKit) |
| `Sources/MimacApp` | SwiftUI app |
| `Sources/mimacctl` | CLI for the collector |
| `Sources/mimac-spike`, `Sources/mimac-calibrate` | Feasibility probes and rail calibration |
| `DESIGN.md` | UI design system |
| `docs/planning` | Phase notes and feasibility measurements |

Run the tests with `swift test`.

## Contributing

The most useful contribution right now is **running Mimac on a Mac that isn't an M5** and
reporting what you see: your Mac model, whether the Power column adds up to the draw shown at
the top, and the `systemPowerWatts` and `powerBreakdown` fields from
`.build/release/mimacctl snapshot`. M1–M4, Pro/Max/Ultra and desktop Macs all need their rails
checked.

Bug reports and pull requests are welcome. Mimac reads undocumented sensor keys, so macOS updates
can break readings — issues with the Mac model and macOS version are especially helpful.

## License

[MIT](LICENSE). Tool icons in `Sources/MimacApp/Resources/ToolIcons` come from
[Simple Icons](https://simpleicons.org/) (CC0); the marks belong to their owners.
