# Timer performance

Run a release-mode benchmark from the repository root:

```sh
bash scripts/performance-test.sh --seconds 15 --rounds 2 --output build/performance/my-run
```

Use a fresh output directory each time. The developer benchmark requires the app toolchain and ripgrep (`rg`). Run in a logged-in macOS desktop session. The probe keeps its diagnostic popover open during the visible scenarios, including when another app gains focus. It creates a temporary menu-bar item, exercises the real `AppModel`, status item, popover, timer lifecycle, SwiftUI controls and native dial, then exits. Your running Sessions app and its preferences are left alone. Notification permission, delivery and sounds use a test backend so the run produces no alerts.

Each scenario has two seconds of settling time followed by the requested measurement windows. The scenarios cover idle, **running before opening**, **running with the popover open**, **running after closing**, **running with only a symbol**, settings while running, and paused with the popover open/closed. Timer and popover state are checked before and after every window. A failed or interrupted run exits with an error and preserves completed samples.

A small diagnostic extension is appended only to the copied `StatusBarController.swift` to suspend its outside-click/deactivation dismissal monitors during a sample. Timer, drawing, layout and production source files in the repository are unchanged by this instrumentation. The manifest records the exact compiled snapshot, including that extension.

The output directory contains `results.json`, `run.log`, a frozen source snapshot, its SHA256 manifest, the optimized probe binary and compiler output. `--build-only` builds the probe for running or profiling separately. `--source-root DIR` tests another source snapshot; it must contain `Package.swift`, `Sources/`, and `Tests/`.

CPU is the increase in **all-thread user + system process CPU time** (`getrusage`) divided by monotonic elapsed time, multiplied by 100. 100% represents one fully occupied core. Kernel interrupt wakeups come from `TASK_POWER_INFO`; they are not the number of application timer callbacks. RSS includes resident shared framework memory and is not a measure of private app allocations. Logging and report writes happen between samples, apart from one small measurement-start log line.

## Recorded comparison — 2026-11-03

Host: Apple M4, 10 CPU cores, 16 GB RAM, macOS 26.4.1 (25E253). Both versions use optimized Swift code and the same CPU counter/timing routine. Baseline: `2a0059cc05fee85ae75ed572f8c9b8e44447ed8f`. Each row aggregates two nominal 15-second windows, excluding startup and window animation. CPU numbers are time-weighted means. Clock update counts cover the measurement windows only.

| Scenario | CPU before | CPU after | Popover clock updates, before → after |
|---|---:|---:|---:|
| `hidden-idle` | 0.004% | 0.008% | 0 → 0 |
| `hidden-running-before-open` | 0.315% | 0.343% | 31 → 0 |
| `open-running` | 2.707% | 0.668% | 30 → 30 |
| `hidden-running-after-close` | 2.447% | 0.371% | 30 → 0 |
| `hidden-symbol-running` | 2.406% | 0.008% | 31 → 0 |
| `settings-running` | 0.323% | 0.344% | 30 → 30 |
| `open-paused` | 0.050% | 0.047% | 0 → 0 |
| `hidden-paused` | 0.106% | 0.018% | 0 → 0 |


The uninstrumented release `.app` was also launched with an isolated bundle identifier and preferences and an already running timer. External kernel counters measured open-running: **0.686% CPU** over 30.0 s, closed-running: **0.368% CPU** over 30.0 s. The executable code was copied from the production bundle; only bundle metadata and its ad-hoc signature changed for isolation, and an exact signature reconstruction verified the measured binary. Its real AppKit windows and running state were checked before and after each sample. A separate symbol-only, closed-popover session completed its deadline and persisted `waiting / shortBreak / 1 completed session`, without a display tick or a read-time recovery reducer. External process CPU counters used the host Mach timebase conversion and were calibrated against `ps` accumulated CPU time. The temporary app, registration and preferences were removed.

Machine-readable [comparison and actual-app results](results-2026-11-03.json) include source hashes, ranges, CPU/wakeup counters and deadline completion evidence. Full raw logs, source snapshots and native window captures remain under `build/performance/`.

The user's original 3–4% hidden / 6–7% expanded readings were observed in Activity Monitor. The controlled baseline reproduced the hidden-after-open problem at about 2.4–2.5%; absolute readings differ with sampling, host load and hardware. These measurements are steady-state averages, not promises that instantaneous CPU can never spike.

## What changed

- The retained popover previously shared the menu bar's per-second clock. It continued updating its dial and SwiftUI fitting/layout graph after closing. The popover clock now freezes while hidden and catches up on opening; the menu bar has its own clock.
- A fixed-size native drawing surface updates only the countdown and progress arc. Clock changes no longer invalidate the surrounding SwiftUI `ViewThatFits`/`ScrollView` layout. Fonts, geometry, themes, captions, contrast handling, controls and glass styling are retained.
- With the popover closed and no time field selected, a running timer sleeps until the earlier of its absolute deadline and local midnight. Opening the timer, hovering the status item for its tooltip, enabling VoiceOver or selecting the time field restores second updates. Idle and paused states continue using the local-midnight timer.
- The timer still uses absolute deadlines. Hiding the UI does not defer completion, notification delivery, persistence, day rollover or wake recovery.

A menu bar that displays seconds still needs one visible update per second. The goal is to keep that small amount of work and avoid hidden rendering or continuous animation. No global polling loop, display link, or new dependency was introduced.

## Verification

`bash scripts/test.sh`: 119 tests in 14 suites passed. New regression coverage includes hidden display-clock freezing, current time on reopening, live demand rescheduling for tooltip/VoiceOver/time fields, deadline and local-midnight scheduling, native accessible countdown updates, clock ticks not invalidating the SwiftUI dial body, and two-line wrapping for a long Russian paused caption. Existing tests cover persistence, notification races, sounds, sleep recovery, phase navigation and time zones/DST.

Native before/after window captures were inspected in light and dark themes for running, paused, Russian two-line long-break waiting/paused states, the 180-minute limit, half progress and the last remaining second. Actual popover closure, anchor hiding, menu-bar time, native accessible time, reopening and localization were checked against live windows. A read-only independent code review found no actionable issues. Full VoiceOver user interaction and battery power consumption were not measured.

The underlying energy approach follows Apple's guidance to [avoid drawing invisible content](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/EnergyGuide-iOS/AvoidExtraneousGraphicsAndAnimations.html) and [minimize timer work](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/EnergyGuide-iOS/MinimizeTimerUse.html); [SwiftUI performance guidance](https://developer.apple.com/documentation/Xcode/understanding-and-improving-swiftui-performance) informed the layout profiling.
