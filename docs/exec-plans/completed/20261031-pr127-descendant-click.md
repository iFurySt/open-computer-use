# PR #127: constrain descendant clicks

- Merge latest main, preserve #126 coordinate fix and original contributor commits.
- Review coordinate and indexed click fallbacks, reject degenerate frames, prevent window-index clicks from pressing window contents.
- Add real AppKit/native MCP regression: blank coordinates, actionless row, window index, intentional button/close actions. Run a pre-fix negative control and #126 smoke.
- Validate Swift suite, documentation, clean diff, then push original PR branch.
- Status: complete. 402 Swift tests (9 skipped) passed; real AppKit/native MCP regression passed, pre-fix negative control failed. Active desktop prevented foreground/pointer stability assertions; global pointer fallback was disabled. See existing coordinate-click history.
