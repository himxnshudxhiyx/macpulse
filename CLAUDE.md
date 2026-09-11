# MacPulse — working context

Native macOS performance monitor (SwiftUI + SwiftPM, no Xcode project). Reads
CPU, memory, storage, network, processes, sensors via Mach / `sysctl` / IOKit.
No network code anywhere in the app.

**Keep this file current.** Whenever you change behaviour, add a feature, or
learn something the hard way, update the relevant section below in the same
change — especially *Landmines*. It is the first thing read in a new session.

## Commands

```bash
./build.sh                      # compile + icon + bundle + ad-hoc sign → build/MacPulse.app
swift build -c release          # compile only (faster inner loop)
open build/MacPulse.app

# Cleanup safety tests — run these after ANY change to CacheScanner
swiftc -parse-as-library Sources/MacPulse/Core/CacheScanner.swift \
    Sources/MacPulse/Core/Sysctl.swift Tests/CleanupTests.swift \
    -o /tmp/cleanup-tests && /tmp/cleanup-tests
```

The build must stay at **zero warnings**. Check with
`./build.sh 2>&1 | grep -c warning:`.

Installed copy lives at `/Applications/MacPulse.app`. To update it:

```bash
pkill -x MacPulse; rm -rf /Applications/MacPulse.app; cp -R build/MacPulse.app /Applications/
```

## Layout

| Path | Role |
| --- | --- |
| `Sources/MacPulse/Core/` | Measurement only. One monitor per subsystem, each returning a plain `…Sample` struct. No SwiftUI. |
| `Sources/MacPulse/Core/SystemMetrics.swift` | The only `ObservableObject` the UI observes. Owns the timer, drives every monitor on one serial queue, publishes one coherent frame. Also holds `healthScore` and `advisories`. |
| `Sources/MacPulse/Views/` | One file per panel + `Components.swift` for shared building blocks (`Card`, `RingGauge`, `TrendChart`, `StatTile`, `UsageBar`, `InfoRow`, `PageScaffold`). |
| `Sources/MacPulse/App/` | Lifecycle: `@main`, `AppDelegate`, menu bar readout and popover. |
| `Tools/make-icon.swift` | Renders the app icon; called by `build.sh`. |
| `Tools/uitest.swift` | Verification helpers — see *Verifying changes*. |

Conventions: `Fmt.*` (in `Sysctl.swift`) formats every byte, rate, percent and
duration — never format inline. `Severity.color(for:)` maps a 0–1 fraction to
the shared green→red ramp, so a colour means the same thing in every panel.

## Landmines

Each of these cost real debugging time. Do not undo them.

- **`TemperatureMonitor` must outlive its service refs.** HID service refs
  borrow the client's locks; releasing the client and then reading a sensor
  aborts the process (`BUG IN CLIENT OF LIBPLATFORM: os_unfair_lock is
  corrupt`). The client is held in a property for exactly this reason.
- **`IOHIDEventSystemClient` is not thread-safe.** `TemperatureProvider` builds
  it on the sampler queue and reads it only from there. Never construct it on
  the main actor.
- **The HID sensor functions are private.** Resolved via `dlsym`, so every
  temperature is `Optional` and the UI hides cleanly when they vanish. Do not
  link them or assume they exist.
- **`MenuBarExtra` clips a SwiftUI label** to one truncated line. The two-line
  readout is drawn into a template `NSImage` (`MenuBarReadout.render`). Do not
  "simplify" it back to a `VStack` of `Text`.
- **The toolbar draws its capsule tight around the content**, so the principal
  item supplies its own `.padding(.horizontal, 10)`.
- **Activation policy follows window presence**, driven by `willClose` +
  `didBecomeKey` notifications in `AppDelegate.syncActivationPolicy`. Closing
  the window drops the Dock icon; any window appearing brings it back. Watching
  only `willClose` breaks reopening from Spotlight.
- **AppKit controls render desaturated when the window is inactive.** A switch
  looks "off" when it is on. State that matters is spelled out in a text badge
  (see the Startup card) rather than left to the tint.
- **`SMAppService.mainApp` registers one exact bundle.** Register the
  `/Applications` copy, never `build/`.
- **The process table comes from `ps`, deliberately.** `libproc` and
  `proc_pid_rusage` only report on other users' processes as root; `ps` covers
  every process unprivileged. Do not "upgrade" this without checking root
  processes still appear.
- **`CacheScanner` is the only code that deletes anything.** Its guarantees —
  fixed allow-list, `$HOME`-only re-checked at delete time, contents-only,
  TCC-protected folders skipped — are covered by `Tests/CleanupTests.swift`.
  Changing the scanner means running those tests.
- **Walking Apple's guarded cache folders triggers privacy prompts**
  ("would like to access your media library"). `CacheScanner.isProtected`
  filters them during both scan and clean.
- **Monitors are `@unchecked Sendable`** because they are confined to
  `SystemMetrics.queue`. That conformance is only sound while that stays true.

## Verifying changes

The app usually sits behind a terminal, so capture it by window id rather than
capturing the screen:

```bash
WID=$(swift Tools/uitest.swift window-id | head -1)
screencapture -x -o -l $WID /tmp/shot.png       # ignores occlusion
swift Tools/uitest.swift policy                 # Dock icon state
swift Tools/uitest.swift click <x> <y>          # synthetic click, screen points
swift Tools/uitest.swift sensors                # raw sensor dump
```

Launch hooks for jumping straight to the thing under test:

```bash
open -n --env MACPULSE_PANEL=cleanup build/MacPulse.app
open -n --env MACPULSE_SCAN_ONLY=xcode-derived build/MacPulse.app
open -n --env MACPULSE_LOGIN_ITEM=register /Applications/MacPulse.app
```

Screen points are screenshot pixels ÷ 2 on this Retina display — check the real
size with `sips -g pixelWidth`, it is not always 3024 wide.

When a change touches a panel, actually look at it. Several bugs here were only
visible in a screenshot (clipped menu bar label, flush toolbar pill, a switch
that looked off).

## Current state

Nine panels: Overview, CPU, Memory, Storage, Network, Processes, Open Apps,
Cleanup, System. Menu bar shows a two-line CPU/RAM readout with SoC temperature
beside it, plus a popover with headline stats, top apps and the login switch.
Starts at login via `SMAppService` (registered); a login launch opens menu-bar
only. Closing the window leaves the app running without a Dock icon.
