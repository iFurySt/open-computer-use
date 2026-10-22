# Agent display cost (macOS)

What the agent display (`window_placement=agent_display`, a `CGVirtualDisplay`) costs in CPU,
GPU, memory and energy, which settings change that, and what each setting does to the agent's
captures and input. Measured to choose the display's settings; the chosen values are in
`AgentDisplay.refreshRate` and `packages/OpenComputerUseVirtualDisplayShim`.

## Environment and noise

| Item | Value |
| --- | --- |
| Machine | Apple M5, 16 GB, built-in 3024x1964 Retina (ProMotion, 120 Hz), no external display |
| macOS | 27.2 (26B118), "Displays have separate Spaces" on, dynamic wallpaper |
| Chrome | isolated `--user-data-dir`, `--app=` window 600x420, page turns a 100x100 box every animation frame (a 400x300 box for the "large" rows) and counts frames in its title |
| Covered | `OpenComputerUseFixture` window over the Chrome window, so the page is `hidden` unless something pins it |
| Date | 2026-10-23 |

The machine was not idle. Other agents built Swift and drove apps, and a person used it. WindowServer
sat at 35 to 50% of one core with no agent display at all, and swung between 15 and 50% in one run.
So every configuration ran 4 or 5 times in alternating order (forward, then reverse), 10 s per sample,
and WindowServer is reported as the median of the paired difference to the "none" sample of the same
round. WindowServer CPU is `ps` CPU time over the sample; Chrome CPU and energy are
`proc_pid_rusage` over Chrome's process tree; frame rate is the page's own count. GPU utilisation
(`IOAccelerator` "Device Utilization %") and GPU memory moved with other apps by more than any
difference here and are not reported. No number needs root.

## 1. The parked app draws at the display's refresh rate

Medians of 4 rounds; WindowServer column is percentage points of one core above "none".

| Configuration | Page fps | Chrome CPU | Chrome energy | WindowServer vs none |
| --- | --- | --- | --- | --- |
| none: covered on the person's screen, page hidden | 0 | 0.3% | 4 mW | 0 (44.3% absolute) |
| upstream display, 1920x1080 @ 60 Hz, hiDPI 1, nothing parked | 0 | 0.2% | 4 mW | +2.4 |
| 1920x1080 @ 24 Hz, hiDPI 0, nothing parked | 0 | 0.3% | 5 mW | +0.5 |
| **upstream: parked on 1920x1080 @ 60 Hz, hiDPI 1** | 60.2 | 8.3% | 152 mW | +4.0 |
| parked, 60 Hz, hiDPI 0 | 60.2 | 8.0% | 125 mW | +3.8 |
| parked, 24 Hz, hiDPI 1 | 24.3 | 4.7% | 89 mW | +0.4 |
| **chosen: parked, 24 Hz, hiDPI 0** | 23.9 | 4.8% | 78 mW | +1.8 |
| parked on 800x600 @ 24 Hz, hiDPI 0 | 24.0 | 4.9% | 64 mW | +1.0 |
| large animation, parked @ 60 Hz, hiDPI 1 | 60.1 | 14.4% | 102 mW | +5.2 |
| large animation, parked @ 24 Hz, hiDPI 0 | 23.9 | 7.4% | 76 mW | -2.0 (one sample at 10%) |

Chrome energy (`ri_energy_nj`) moved more between runs than CPU did: 102 to 152 mW parked at 60 Hz
and 76 to 80 mW at 24 Hz across three runs.

Across all runs the WindowServer difference was consistent in sign only for 60 Hz: an idle 60 Hz
display +2.3, +2.4, +2.8 and +3.1 points in four runs; a parked animating window at 60 Hz +4.0 to
+5.2. At 24 Hz the differences (-7.9 to +2.7 across runs, idle or parked) are inside the noise. Chrome's own numbers are not
noisy: four separate runs gave 7.6 to 8.3% at 60 Hz and 4.6 to 4.8% at 24 Hz for the small
animation.

A Chromium page on a visible window runs `requestAnimationFrame`, CSS animation and compositing at
the refresh rate of the display the window is on. On the agent display nobody sees those frames.

## 2. Refresh rates the display accepts

| Requested | Result |
| --- | --- |
| 120, 60, 30, 24 Hz | accepted; `CGDisplayModeGetRefreshRate` reports the requested rate |
| 23.9, 20, 10, 5, 1 Hz | `applySettings:` returns NO, no display |

`+[SLVirtualDisplay capabilities]` (SkyLight) reports `minimumRefreshRate = 24`, pixels per point
0.25 to 4 and at most 16384x16384 pixels. 24 Hz is the floor.

## 3. hiDPI and size

| Settings | Modes offered | Active mode |
| --- | --- | --- |
| 1920x1080, hiDPI 1 (upstream) | 20, of them 9 HiDPI (for example 960x540 points on 1920x1080 pixels) | 1920x1080 points, 1920x1080 pixels |
| 1920x1080, hiDPI 0 | 12, none HiDPI | the same |
| 800x600, hiDPI 0 | 3 | 800x600 at 1x |

The display comes up at 1x either way, so a parked window renders and captures at 1x (half the
linear resolution of the Retina screen) with both values, and section 1 shows no cost difference.
hiDPI 0 is still chosen: with HiDPI modes on offer, macOS can bring the display up in one of them
later (macOS keeps a chosen mode per display identity, which is fixed here), and the same points would
then be backed by four times the pixels.

Size: WindowServer's footprint was 40 to 90 MB higher while a 1920x1080 display existed (paired per
round, median about +74 MB), and fell back after removal. An 800x600 display did not measure
smaller at this noise (about ±40 MB), and its CPU numbers match 1920x1080. A display smaller than
the parked window makes it hang off the display or lets apps shrink it to fit, and `restore` puts
back only the position. Kept at 1920x1080.

## 4. Creating and removing the display

Scratch harness (see the end), 5 repetitions each for 1920x1080 @ 60 Hz hiDPI 1, 1920x1080 @ 24 Hz hiDPI 0 and 800x600 @ 24 Hz hiDPI 0, CPU time of
every process in a 4 s window before creation, after creation and after removal.

| Step | Measured |
| --- | --- |
| `applySettings:` returns | 91 to 142 ms (median 97 to 99) |
| bounds and active list report the display | 16 to 51 ms later |
| removed from the active list after release | 10 to 63 ms |
| CPU of GUI processes, 4 s window: idle / after create / after remove | 2.3 to 2.5 s / 3.3 to 3.4 s / 3.1 to 3.3 s |
| processes that woke (at least 10 ms CPU) | 5 to 12 / 24 to 27 / 23 to 26 |
| WindowServer in that window | 1.73 to 1.79 s / 1.87 to 1.91 s / 1.91 to 1.98 s |

Every running app gets the screen-configuration change. One create costs about 0.9 to 1.1 CPU-seconds
across the GUI and one removal 0.6 to 0.9, independent of size, refresh rate and hiDPI. The largest
single contributors were MenuBarAgent (0.18 to 0.29 s per create: the new display gets its own
menu bar), ControlCenter (about 0.1 s), and in some repetitions Safari and its WebKit processes
(up to 0.7 s). Against an idle 24 Hz display (section 1, at most about 2 points of one core), a
create and removal pair equals roughly 80 to 400 s of keeping the display. Upstream still removes the
display as soon as nothing is parked; a linger would only pay off when parks come in bursts.

There is no `CGVirtualDisplay` property that keeps the menu bar, Dock or wallpaper off the display.
With separate Spaces on, the display gets its own Space and menu bar; that shows up as the
creation cost above, and the menu bar and wallpaper processes were not measurably busier while the
display sat idle.

## 5. Agent function at each setting

Four rounds, five clicks each, on the parked window (`sky_click` on a button that flips the page
colour, then `SLSHWCaptureWindowList` polled until a pixel shows the new colour).

| Configuration | Clicks landed | `sky_click` returns | Click to pixel p50 / max | Click to title | `sky_key` text in title | Web AX tree |
| --- | --- | --- | --- | --- | --- | --- |
| 60 Hz, hiDPI 1 | 20/20 | about 90 ms | 99 / 136 ms | 192 ms | 118 ms | yes |
| 24 Hz, hiDPI 0 | 20/20 | about 90 ms | 102 / 124 ms | 193 ms | 120 ms | yes |
| 24 Hz, hiDPI 1 | 20/20 | about 90 ms | 95 / 113 ms | 192 ms | 126 ms | yes |
| 800x600, 24 Hz | 20/20 | about 90 ms | 99 / 107 ms | 191 ms | 118 ms | yes |

The first capture taken after `sky_click` returned already showed the new colour in every click
at every rate: the click recipe's own gaps outlast a 42 ms frame. Content that changes on its own
(a timer, streaming text) can be up to one frame old in a capture: 17 ms at 60 Hz, 42 ms at 24 Hz.

## 6. The occlusion keep-alive after `restore`

`get_app_state` pins the window it reads (WindowServer occlusion notifications off) whenever the
window is unoccluded, and a window on the agent display always is. After `restore` the window is
back under the person's windows but still pinned, so its app keeps drawing it at the person's
display rate until the turn ends (or, for a host that never signals the end of a turn, until the
MCP connection closes). Windows on the agent display are no longer pinned (they are visible there
without it), so a restored window goes back to the state it had before it was parked.

`testParkedWindowCost` (production `AgentDisplay.park` / `restoreAll`, one run each; Chrome was
launched seconds earlier, so its CPU includes start-up work that the section 1 runs did not have):

| Build | Covered | Parked | Restored under the cover |
| --- | --- | --- | --- |
| upstream (60 Hz, hiDPI 1, pin kept) | 0 fps | 59.5 fps, Chrome 14.8% | **118.6 fps, Chrome 16.9%**, page `visible` |
| this change, `OPEN_COMPUTER_USE_AGENT_DISPLAY_REFRESH_HZ=60` | 0 fps | 60.9 fps, Chrome 15.5% | 0 fps, Chrome 0.1% |
| this change, default 24 Hz | 0 fps | 23.8 fps, Chrome 9.9% | 0 fps, Chrome 0.5% |

Click to pixel in the same runs: 97 to 114 ms (upstream), 101 to 113 ms (60 Hz), 105 to 140 ms
(24 Hz), five of five clicks each. In the sweep harness, the same restored-and-pinned state measured
118 to 121 fps and 8 to 18% Chrome CPU across three rounds.

The same applies to every window the keep-alive pins on the person's own screen: a pinned
animating page draws at 120 fps while covered. That is the keep-alive's purpose and is unchanged.

## Not covered

- One machine, one macOS build, one browser engine. WebKit and Core Animation content were not
  measured; they are expected to follow the window's display link the same way.
- Wake-ups, GPU utilisation and GPU memory were sampled but too noisy to report.
- `refreshDeadline` (0.01 and 1.0) and `isReference` (`CGVirtualDisplaySettings`) are accepted and
  left the mode and the page's frame rate unchanged (23.8 to 24.1 fps); their purpose is unknown.
  The other descriptor properties (`terminationHandler`, vendor / product / serial, colour primaries,
  the mode's transfer function, rotation) describe the display's identity and colour, not its work.
- Lower rates than 24 Hz would need a display that is not a `CGVirtualDisplay`.

## Reproduce

```sh
# production path: covered, parked, restored; Chrome fps/CPU, WindowServer CPU, click to pixel
OPEN_COMPUTER_USE_RUN_AGENT_DISPLAY_COST=1 swift test --filter AgentDisplayLiveTests/testParkedWindowCost
OPEN_COMPUTER_USE_RUN_AGENT_DISPLAY_COST=1 OPEN_COMPUTER_USE_AGENT_DISPLAY_REFRESH_HZ=60 \
  swift test --filter AgentDisplayLiveTests/testParkedWindowCost

# the existing regression
OPEN_COMPUTER_USE_RUN_AGENT_DISPLAY_LIVE_TEST=1 swift test --filter AgentDisplayLiveTests
```

The lever sweep (hiDPI, size, idle display, creation churn, rejected rates) used a scratch harness
that drove the private classes with every setting exposed; it is not in the repo. The production
test above reproduces the refresh-rate and keep-alive rows.
