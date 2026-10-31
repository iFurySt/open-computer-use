# JS getAXState skips unused capture and returns full text by default

Date: 2026-10-31

Request (condensed): the JS AX getter should not pay for a screenshot it never
returns, and should return the same full-text tree as the reference engine's AX read.

- `app.getAXState()` now sends `include_screenshot: false` and `text_limit: "max"`
  unless the caller sets `includeScreenshot`, `textLimit` or `includeAX: false`.
- With capture skipped, the getter removes only the separate
  `Screenshot omitted by include_screenshot=false` text item; tree text and every
  other warning are kept.
- Native `get_app_state`, `getScreenshot()` and `getAXStateAndScreenshot()` keep
  their defaults.
- Updated the REPL instructions, `docs/selective-observation.md`,
  `docs/references/js-repl.md`, `docs/ARCHITECTURE.md` and the skill usage reference.

Why: through the real JS launcher, Worker and native MCP path, a large chat-app
window read took a median of 535 ms with the old defaults and 480 ms AX-only with
full text (local measurement; window content and machine load affect it). The
getter never returned the image, so capture and encoding were wasted work.

Compatibility: after a default `getAXState()`, screenshot-coordinate actions need a
fresh screenshot, as with an explicit `includeScreenshot: false` today. Text values
are no longer cut at 500 characters by default, so long values make the output
longer; pass `textLimit: 500` to keep the old limit.

Validation: all 57 Node tests in `scripts/node-repl/` and the 4 tests in
`scripts/tests/` passed, including the updated argument checks for both REPL
session types and a new test that keeps tree text and other warnings while explicit
capture stays available. No Swift source changed. `make check-docs` passed.
