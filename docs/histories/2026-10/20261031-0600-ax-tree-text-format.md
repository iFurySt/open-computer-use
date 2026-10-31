# Compact macOS AX tree spellings with one tab per level

Date: 2026-10-31

Request (condensed): shrink full macOS accessibility-tree text without dropping any
node, name, value, state or action index, and pick the indentation that models read
most reliably.

- Added `AXTreeTextFormatting`. Real AX trees now spell `container` as `group`,
  `settable` as `w`, `settable, string|boolean|float` as `w:str|w:bool|w:float` and
  `Value: x` as `= x`. Node selection, `ElementRecord` data, raw actions and frames
  are unchanged; only the rendered spelling changes.
- `AppSnapshot.renderedText` adds one legend line after the App/Window lines for AX
  observations: `[w=settable]` in the default mode.
- Indentation stays one tab per tree level by default.
  `OPEN_COMPUTER_USE_AX_INDENTATION=tab4` packs four levels into one tab and uses
  spaces for the remainder, with the legend `[tab=4 w=settable]`. Unknown values use
  the default. The variable is forwarded to the app agent like other
  `OPEN_COMPUTER_USE_*` variables.
- Native tool descriptions and fixture-bridge synthetic snapshots are unchanged.
- Extended the semantic AX fixtures: both spellings keep the same record keys, backing
  elements, roles, raw actions, frames and hierarchy depth (to 23 levels); the trait
  encoding round-trips for every state/type combination; `tab4` columns equal the
  depth for 0-64; the two indentation modes differ only in leading whitespace.
- Documented the spelling in `docs/ARCHITECTURE.md` and in the JS REPL instructions.

Why the default is one tab per level: two models (one Claude and one Codex model,
low effort, tools disabled) answered the same 39 program-checked questions per window
for a large chat-app window and a browser window. One tab per level was the only
format both read without error (156/156); `tab4` scored 149/156 (writable-flag
misreadings by one model and tree-structure misreadings by the other), and the
reference engine's own text format scored 151/156. Input tokens were about the same
for both indentation modes (41,223 versus 41,214 for one model; 25,798 versus 26,728
for the other). This is one pass per cell, not a general accuracy result.

Size, from local captures of the same live windows taken at different times (so the
content differs slightly): with one tab per level the chat-app window was 44,801
characters against 46,029 before this change (about -3%), and the browser window
11,345 against 12,606 (about -10%). `tab4` gave 37,712 and 10,475 (about -18%).

Validation: see the pull request for the exact `swift build`, focused test and full
test counts. `make check-docs` passed.
