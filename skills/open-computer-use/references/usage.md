# Open Computer Use Usage

Read this reference when the task requires direct Computer Use tool calls, MCP configuration, or platform-specific behavior.

## MCP Server

For MCP clients that support stdio servers:

```toml
[mcp_servers.open_computer_use]
command = "open-computer-use"
args = ["mcp"]
```

Supported npm packages also expose `ocu` as a short alias, so `ocu mcp` is equivalent when available.

Equivalent JSON shape:

```json
{
  "mcpServers": {
    "open-computer-use": {
      "command": "open-computer-use",
      "args": ["mcp"]
    }
  }
}
```

The MCP server exposes:

```text
list_apps
get_app_state
click
perform_secondary_action
scroll
drag
type_text
press_key
set_value
select_text   (macOS runtime only)
```

macOS also exposes `query` for targeted AX lookup. These nine core tools remain the cross-platform compatibility surface. The bundled Codex plugin uses a
code-first adapter instead and advertises only `js` and `js_reset`. In that
surface, bind an app and compose actions with asynchronous JavaScript:

```js
var app = await cua.getApp("TextEdit");
await app.typeText("Hello");
await app.getAXState();
```

### Selective observation (opt-in)

The native `get_app_state` tool on macOS, Windows and Linux accepts `include_ax` and
`include_screenshot`. Both default to `true`; at least one must remain true.
The REPL forwards the corresponding optional `includeAX` / `includeScreenshot`
booleans:

```js
var editor = await cua.getApp("gedit", { initialState: false });
await editor.getScreenshot({ includeAX: false }); // no AX, focus or selection walk
await editor.click([100, 100]);                   // window-relative coordinates
await editor.getAXState({ includeScreenshot: false }); // no capture or PNG encoding
// Use newly observed element indexes only after inspecting the AX result.
```

Screenshot-only observation invalidates prior element indexes and cached query
aliases for that app, even if the window title is unchanged. Its result explicitly
reports this. Coordinate actions use the newly observed window bounds; element
actions require a fresh AX observation. Existing calls without these options keep
their full native observation behavior. These flags are implemented on all three native platforms; action read-back is unchanged.

These options select collection, not image deduplication. An unchanged screenshot
is still returned when requested. macOS/Linux JS actions already disable automatic
read-back, and getAXState does not emit images; includeScreenshot:false additionally skips
native capture on all three platforms. See `docs/selective-observation.md` for real GTK
and Worker JS validation.

The code-first surface also forwards macOS background-operation options:

```js
var chrome = await cua.getApp("Google Chrome");
await chrome.getAXState({ windowPlacement: "agent_display" });
await chrome.typeText("hello", { keyMethod: "sky_key" });
await chrome.pressKey("cmd+a", { keyMethod: "sky_key" });
await chrome.getAXState({ windowPlacement: "restore" });
```

Bindings persist across `js` calls until `js_reset`. See
`docs/references/js-repl.md` for the full API and security boundary.

The npm CLI can use the same code-first runtime without an MCP host:

```sh
ocu capabilities
ocu js 'var apps = await cua.listApps({ emit: false }); nodeRepl.write(apps)'
printf '%s' 'nodeRepl.write(6 * 7)' | ocu js -
ocu js --file ./automation.mjs
ocu repl
```

`ocu js` owns one short-lived Worker/native MCP session. `ocu repl` keeps the
session and top-level bindings for the current terminal until `.exit`, Ctrl-D,
or termination; `.editor` / `.end` accepts multiline input and `.reset`
discards JavaScript bindings. Use `nodeRepl.write(value)` for explicit output.
The native `ocu mcp` surface exposes the nine core tools above, plus `query` on macOS. Run
`ocu capabilities --json` to inspect component availability instead of
inferring support from a command being present in help.

## Direct CLI Tool Calls

Use `call` for one-off checks:

```sh
open-computer-use call list_apps
ocu call list_apps
open-computer-use call get_app_state --args '{"app":"TextEdit"}'
open-computer-use call set_value --args '{"app":"TextEdit","element_index":"1","value":"Draft"}'
```

Use `--calls` for short action sequences that need to reuse the same process state:

```sh
open-computer-use call --calls '[
  {"tool":"get_app_state","args":{"app":"TextEdit"}},
  {"tool":"click","args":{"app":"TextEdit","element_index":"1"}},
  {"tool":"type_text","args":{"app":"TextEdit","text":"Hello"}}
]'
```

Use `--calls-file` when the sequence is too large for a readable shell command:

```sh
open-computer-use call --calls-file examples/textedit-overlay-seq.json --sleep 0.5
```

## Text Limits

Snapshot text is truncated to 500 characters by default and ends with `...` when truncation happens. This keeps normal UI state compact for agent planning and element-targeted actions.

Use a larger text limit when the task depends on longer semantic text, such as chat histories, email bodies, document text, or long form content. Use `max` only when complete text is required:

```sh
open-computer-use call get_app_state --args '{"app":"TextEdit","text_limit":1000}'
open-computer-use call get_app_state --args '{"app":"TextEdit","text_limit":"max"}'
open-computer-use snapshot --text-limit 1000 TextEdit
open-computer-use snapshot --text-limit max TextEdit
```

The same `text_limit` tool argument and `--text-limit` snapshot flag apply on macOS, Linux, and Windows. `text_limit` accepts a positive integer or the string `"max"`.

Action tools return refreshed app state with the default 500 character text limit. If longer text is still needed after an action, run `get_app_state` again with `text_limit: 1000` or `text_limit: "max"`.

## Larger Tree Budgets

Accessibility tree rendering defaults to 1200 nodes and 64 levels on macOS, Linux, and Windows. This keeps normal snapshots bounded while preserving most interactive UI.

Use a larger tree budget when a visible long page, list, table, or web app appears incomplete even after scrolling:

```sh
open-computer-use call get_app_state --args '{"app":"Google Chrome","max_tree_nodes":3000,"max_tree_depth":96}'
open-computer-use snapshot --max-tree-nodes 3000 --max-tree-depth 96 "Google Chrome"
```

`max_tree_nodes` and `max_tree_depth` must be positive integers. They only affect explicit `get_app_state` and `snapshot` calls; action tools still return refreshed state with the default tree budget.

## Choosing Targets

- Prefer app names or bundle identifiers returned by `list_apps`.
- Run `get_app_state` immediately before element-targeted actions.
- Re-run `get_app_state` after navigation, modal changes, page reloads, or failed actions.
- Use coordinate actions only when the rendered tree does not expose the target as an element.
- On macOS, use `app.query` when you know the control's text or role. Bind with
  `await cua.getApp("Safari", { initialState: false })` to skip the initial snapshot.
  Query returns `{ matches, truncated, stop_reason, visited_nodes, window_id, limit, max_nodes }`.
  An empty result only means no matching exposed control was found when `truncated` is false.
  `exact: true` never retries substring matching. Query does not launch or activate the app.
- Query indexes last up to 120 seconds in the same native session (5000 retained handles).
  Use persistent MCP or `ocu repl` for query then action; separate CLI calls cannot share indexes.
  Actions revalidate the process/window/control and current geometry. On failure, query again.
  See [targeted query](../../../docs/targeted-query.md) for options and examples.

## Choosing a Click Method

`click_method` is optional. Omitting it uses `auto`, which preserves the platform's existing semantic-first behavior. Explicit methods never fall back to a different implementation:

- `accessibility`: only invoke the element's accessibility action and require `element_index`.
- `app_post`: bypass accessibility and post a mouse event directly to the target app/window without moving the system pointer. Supported on macOS and Windows.
- `sky_click`: use the macOS private SkyLight background-window path with target-only synthetic focus and a Chromium primer click. It supports left single/double click on a current, on-screen window in the same Space and does not move the system pointer, deactivate the foreground app, change its key/first-responder state, or raise the target window. Its action-result snapshot refresh is read-only. Supported on macOS only.
- `global`: bypass accessibility and use the desktop's global pointer path. Supported on macOS, Windows and Linux, and requires `OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1` because it may move the real pointer or change foreground focus.

Use `app_post` for an exact blank-area or overlay click that must not be redirected to an accessibility descendant:

```sh
open-computer-use call click --args '{"app":"Google Chrome","x":875,"y":375,"click_method":"app_post"}'
```

Use `sky_click` when Chromium ignores `app_post` and the current target window is covered by another window:

```sh
open-computer-use call get_app_state --args '{"app":"Google Chrome"}'
open-computer-use call click --args '{"app":"Google Chrome","x":875,"y":375,"click_method":"sky_click"}'
```

Run `get_app_state` again after the target window moves, closes, changes Space, becomes hidden, or is minimized. `sky_click` is an explicit private-SPI mode: unavailable symbols, a stale window id, unsupported button/count, or failed delivery return an error without falling back to another click implementation.

Use `global` only after explicitly enabling the process-level safety gate:

```sh
OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1 open-computer-use call click --args '{"app":"Google Chrome","x":875,"y":375,"click_method":"global"}'
```

Keep the environment override scoped as narrowly as possible. While it remains enabled, the existing `auto` route may also choose the global pointer path after accessibility cannot handle a click.

Windows returns an unsupported error for `sky_click`; Linux returns an unsupported error for `app_post` and `sky_click`. An unsupported or failed explicit method does not fall back to `auto`.

## Choosing a Keyboard Method

`key_method` on `type_text` and `press_key` is optional. Omitting it uses `auto`, which keeps the existing accessibility-first typing and app-posted key events. Explicit methods never fall back:

- `sky_key`: use the macOS private SkyLight background-window path. It makes the current target window the key window inside its own app (without raising it, moving the pointer, switching Spaces, or deactivating the foreground app), delivers the keys, and releases that state again. Command chords such as `cmd+a`, `cmd+c` or `cmd+v` are performed through the target's own menu bar. Supported on macOS only.
- `global`: Windows press_key only. Requires `OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1` and sends checked physical keys to the verified foreground target. Auto keys keep window-message delivery even when that flag is enabled. It does not apply to type_text.

Use `sky_key` when a Chromium or Electron window is covered by another window or lives on another Space and `auto` typing does not reach it:

```sh
open-computer-use call get_app_state --args '{"app":"Google Chrome"}'
open-computer-use call click --args '{"app":"Google Chrome","x":420,"y":260,"click_method":"sky_click"}'
open-computer-use call type_text --args '{"app":"Google Chrome","text":"hello","key_method":"sky_key"}'
open-computer-use call press_key --args '{"app":"Google Chrome","key":"cmd+a","key_method":"sky_key"}'
```

Covered windows and windows on other Spaces: `get_app_state` never activates or raises a window that is off-screen, and it pins the visibility of every window it captures while that window is unoccluded, so covering it or switching Spaces afterwards keeps Chromium/Electron content in the tree and screenshots live. If the tree ends with a note that the window is covered, the app had already hidden its content before the first snapshot. Either bring the window into view once and snapshot again, or park it on the agent's own invisible display:

```sh
open-computer-use call --calls '[
  {"tool":"get_app_state","args":{"app":"Google Chrome","window_placement":"agent_display"}},
  {"tool":"get_app_state","args":{"app":"Google Chrome","window_placement":"restore"}}
]'
```

Virtual displays are disabled by default. The host must explicitly set
`virtualDisplay.enabled=true` with `ocu config`, or
`OPEN_COMPUTER_USE_VIRTUAL_DISPLAY_ENABLED=true`, before using the examples above.
While disabled, MCP omits `window_placement`, JS guidance omits `windowPlacement`,
and stale `agent_display` calls fail before creating a display. The agent must not
enable this setting on the user's behalf without their request: it adds a system
monitor and can change the user's display arrangement. Existing `restore` and
turn/connection cleanup remain available when disabled.

`agent_display` moves the window's frame onto a virtual display the user never sees (macOS only): the app renders it, exposes its full tree and accepts `sky_click` / `sky_key`, while the user's Space, focus and pointer stay untouched. The window is gone from the user's desktop until `restore`, the assistant turn ends, the MCP/REPL connection closes, or the runtime exits, so treat it as a deliberate, temporary step. `restore` restores every window parked by the runtime for that app. Keep park/action/restore calls in one `js`, REPL, MCP, or `call --calls` session; a one-shot CLI connection restores its background state when it closes. `sky_click` and `sky_key` accept covered and other-Space windows.

`sky_key` types into whatever element the target window has focused, so click or AX-focus the field first. It fails closed for hidden apps (`cmd+h`), stale window ids, and missing private symbols; Windows and Linux return an unsupported error.

## Drag Delivery

`drag` has no method parameter. On macOS the path it takes is decided by the same process-level gate that authorizes `click_method: "global"`:

- Gate unset (default): mouse move / down / dragged / up events are posted directly to the target process with `CGEvent.postToPid`. The system pointer does not move and foreground focus is unchanged. Because the events never pass through the window server, this path cannot start a window-server drag session: window moves, drag-selecting text, and Finder drag-and-drop return without error but have no visible effect.
- `OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1` set for the server process: the drag uses the global pointer path, which drives window-server drag sessions but may move the real pointer and change foreground focus.

Every non-fixture `drag` result includes a text item that begins `Drag delivered via app_post` or `Drag delivered via global pointer path`, so a default drag that did nothing is legible instead of looking like success. For an MCP server the variable belongs in the server entry's `env`, not in the calling shell, and the server must be restarted afterwards.

When the gate is not enabled, treat window-server drags as unavailable and reach the same outcome another way: copy or move files with a shell command instead of a Finder drag, use `set_value` or keyboard selection instead of drag-selecting text, and use the app's own window controls instead of dragging a title bar.

## Text Selection (macOS)

Use `await app.selectText(elementIndex, text, options?)` with a snapshot or `query`
index from the current session. The native CLI/MCP tool is `select_text`.

| Argument | Meaning |
| --- | --- |
| `elementIndex` | The text element's current index. |
| `text` | Exact target text, including whitespace and Unicode spelling. |
| `options.prefix` / `options.suffix` | Text immediately before / after the target, for repeated matches. |
| `options.selection` | `text` (default), `cursor_before` or `cursor_after`. |

Ambiguous or missing text, unsupported selection, text changes and unverified ranges
return errors. The action verifies the applied UTF-16 range even when full action
read-back is off; use `getAXState()` for the next UI observation. It does not activate
the app or fall back to keyboard/pointer input. Linux and Windows do not implement
`select_text` yet.

## Software Cursor

The software cursor keeps a window-relative anchor for its target point. During travel, settle, click
feedback and idle, it follows changes to the target window's frame. If the window moves during travel,
the visible tip lands at the new position immediately, without continuing toward the old position.

Window frames are read on a background worker at up to 30 Hz, with at most one read in flight. Rendering
uses the latest cached frame, so a slow Accessibility response does not block the cursor. The snapshot's
AX window element is preferred; `CGWindowListCopyWindowInfo` is used only when no AX element is available,
because it can report an old origin after a move. A failed read keeps the last usable frame. Tracking is
released when the cursor is cleared or its idle timeout expires.

This follows the window's position, not layout changes inside it. Refresh app state after a layout change
before choosing another target. Input delivery continues to use the existing action paths.

## Platform Notes

### macOS

The macOS runtime uses Accessibility, ScreenCaptureKit, app-posted input events, and explicit private-SkyLight `sky_click` / `sky_key` routes. It normally avoids moving the user's real pointer. The visual cursor overlay is part of the Open Computer Use experience and can be disabled by the surrounding runtime only when needed. Private SkyLight symbols and raw event fields are not API-stable; re-validate `sky_click` after macOS upgrades.

### Windows

The Windows runtime uses UI Automation and Win32 message fallbacks. It must run in a logged-in desktop session. A detached SSH or service context may start the CLI but fail to see top-level windows.

With `OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1`, Windows also supports
explicit global clicks, auto click/scroll fallbacks and physical drags. Real
keyboard input additionally requires an explicit call such as
`await app.pressKey("ctrl+a", {keyMethod:"global"})`; auto key delivery stays on
window messages. Explicit app_post/accessibility clicks keep their selected path.
Global input can move the pointer and activate the target. Stale window geometry,
occluded points and foreground failures are refused; observe again or make the
target visible. The runtime does not synthesize Alt to force activation.


### Linux

The Linux runtime uses AT-SPI2 through the desktop session bus. It must run in a logged-in graphical session with usable accessibility services. Wayland screenshot and coordinate input support is compositor-dependent and best-effort.

## Safety

Pause and ask the user before actions that affect external systems or sensitive local state, including sending messages, submitting forms, deleting files, approving prompts, uploading files, or interacting with password managers.

## Persisted screenshot settings

Use `ocu config` to inspect effective values and their sources. `ocu config set image.format jpg` or `ocu config set image.maxLongEdgePixels 1024` persists macOS screenshot preferences in the user config file. ENV overrides take precedence; `ocu config reset KEY` removes a saved preference. Windows/Linux screenshot behavior is unchanged.
