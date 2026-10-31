# Batch macOS AX attribute reads within one snapshot

Date: 2026-10-31

Request (condensed): make full macOS accessibility-tree reads of large Electron and
browser windows as fast as the reference computer-use engine, without losing any
node, name, value, state or action index.

- Added `AXSnapshotReadCache`. The first read of an element in a tree walk fetches
  the 20 attributes the renderer commonly uses with one
  `AXUIElementCopyMultipleAttributeValues` call. Successful and
  unsupported/no-value results, action names and settable flags are kept only for
  that walk. Transient errors are not kept, so a later read of the same attribute
  tries again.
- `SnapshotBuilder` opens a fresh cache scope for the main walk, each lazy web-area
  rewalk and the menu bar. Action tools, focus and window queries read live values.
  `OPEN_COMPUTER_USE_DISABLE_AX_READ_CACHE=1` turns the cache off for output
  comparison.
- Compact generic action targets that already have a title, label, value, summary
  or placeholder no longer repeat their `Frame` in the text. Anonymous targets keep
  it. Every `ElementRecord` keeps its frame, so coordinate and element actions are
  unchanged.
- Added semantic AX fixtures that drive the production `TreeRenderer` through an
  injected attribute source, with logical IDs as an independent oracle for roles,
  names, values, raw actions, frames, repeated names and fresh values across reads.
- Updated `docs/ARCHITECTURE.md` and the release notes.

Why: profiling one read of a large chat-app window (about 930 elements) spent
3376 ms of 3523 ms (96%) in the tree walk, which made 68,351 single-attribute AX
calls. AX calls are cross-process round trips, so batching them per element removes
most of the wait.

Measurements (local direct reads of the same windows, median of three five-read
medians; the timing harness is not part of this change): the chat-app window went
from a 2393 ms baseline median (3116 ms in a first run) to 500 ms, against 479 ms
for the reference engine; a browser window went from 452 ms to 104 ms, against
121 ms. Timings depend on the machine and window content.

Validation: see the pull request for the exact `swift build`, focused test and full
test counts. `make check-docs` passed.
