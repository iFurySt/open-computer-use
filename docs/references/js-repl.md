# JavaScript REPL Computer Use

Open Computer Use ships a Node.js adapter for hosts that want a code-first
Computer Use surface. The adapter exposes two model-facing MCP tools, `js` and
`js_reset`, and keeps the native MCP server behind it (11 tools on macOS, 9 on Linux/Windows).

## Why this shape

A UI flow usually needs several ordered operations: inspect, act, inspect again,
branch, retry, and verify. Discrete model-facing tool calls pay one model round
trip per operation and repeatedly serialize intermediate state. JavaScript makes
the sequencing local: deterministic actions and the final state read can happen
in one `js` call.

The design follows the current official code-first workflow without copying its
proprietary packages. In the inspected official bundle, the host provides a
general `node_repl` and the Computer Use plugin tells the model to import
`@oai/sky`. Open Computer Use packages the equivalent orchestration boundary as
two plugin-local MCP tools because an arbitrary MCP host does not necessarily
provide that general REPL:

1. a persistent Node.js REPL owns top-level JavaScript bindings and top-level
   `await`;
2. an asynchronous app-bound `cua` API converts JavaScript calls into native MCP
   `tools/call` requests;
3. the existing Swift, Go, and Python-backed runtimes continue to own app
   discovery, screenshots, accessibility, and input;
4. a worker boundary lets the host terminate CPU-bound JavaScript on timeout and
   start a fresh kernel.

## API

```js
var app = await cua.getApp("TextEdit");
await app.click(12);
await app.typeText("Hello");
await app.getAXState();
```

`cua.getApp(...)` accepts the same app name or bundle identifier as the native
runtime and emits the initial accessibility state. The returned binding exposes:

```text
getAXState({ emit?, textLimit?, maxTreeNodes?, maxTreeDepth?, windowPlacement?, diff?, disableDiffing? })
getScreenshot({ emit?, windowPlacement? })
getAXStateAndScreenshot({ emit?, textLimit?, maxTreeNodes?, maxTreeDepth?, windowPlacement? })
click(elementIndexOrPoint, options?)
drag([fromX, fromY], [toX, toY])
pressKey(key, options?)
scroll(elementIndex, direction, pages?)
setValue(elementIndex, value)
selectText(elementIndex, text, { prefix?, suffix?, selection? })  // macOS
typeText(text, options?)
performSecondaryAction(elementIndex, action)
```

On macOS, Windows and Linux, observation methods also accept optional `includeAX` and
`includeScreenshot` booleans. `getAXState()` defaults to `includeScreenshot: false`
and `textLimit: "max"`, because it never returns the image; pass
`includeScreenshot: true` or use `getAXStateAndScreenshot()` before
screenshot-coordinate actions. The other getters default both to true. Use
`app.getScreenshot({includeAX:false})` to skip the AX/focus walk. The latter
invalidates previous element indexes; read AX again before element actions.
Disabling both channels is rejected before a native call. These options do not
deduplicate unchanged images. See [selective observation](../selective-observation.md)
for collection semantics and real GTK/Worker validation.

`app.getAXState({ diff: true })` is opt-in and returns a JSON string instead of
the tree text. The first packet is `{"type":"ax-full","revision":n,"text":...}`
with the complete text. Later packets are
`{"type":"ax-diff","baseRevision":m,"revision":n,"added":[...],"changed":[...],"removed":[...]}`:
`added` and `changed` hold `{index, text}` with the full line of each element,
`removed` holds element indexes, and an optional `layout` array gives the new
order of element indexes and non-element lines when it changed. Indentation,
focus, selection and notes are kept exactly; `applyAXStateDiff` in
`scripts/node-repl/ax-state-diff.mjs` rebuilds the full text byte for byte and
rejects a packet whose `baseRevision` does not match. Each app binding keeps its
own baseline. A changed App/Window header, changed observation options, a native
error, duplicate element indexes, a screenshot read or any call without `diff`
(or with `disableDiffing: true`) resets it, so the next diff call returns
`ax-full`. Diffs only shorten the returned text; the native tree is still read
in full.

On Windows, explicit `app.pressKey("ctrl+a", {keyMethod:"global"})` uses
physical SendInput keys and requires `OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1`.
Auto key delivery remains window messages even with this flag enabled. Explicit
app_post clicks remain window messages too. Global input may activate the target
and move the system pointer; stale geometry, occlusion and foreground failures
are refused. See [Windows input](../windows-input.md) for routing and desktop tests.

On macOS, `selectText` selects exact text inside a text element. `prefix` and `suffix`
match the immediately adjacent text to disambiguate repeated occurrences. `selection`
is `text` (default), `cursor_before` or `cursor_after`. Snapshot and `query` indexes
both work in the same session. For example:

```js
var editor = await cua.getApp("TextEdit", { initialState: false });
var fields = await editor.query({ role: "AXTextArea" });
if (fields.matches.length !== 1) throw new Error("Choose the intended text area first");
await editor.selectText(fields.matches[0].index, "target", { selection: "cursor_after" });
await editor.getAXState();
```

Missing/ambiguous text, unsupported range selection, changed text and failed range
verification throw through `js`. Verification still reads the applied range when full
action read-back is disabled. The tool does not use keyboard/pointer fallback or
activate the application. Linux/Windows report the native unsupported-tool error.

Discovery is available through `await cua.getState()` and
`await cua.listApps()`. `listApps()` normalizes the native human-readable app
catalog into an array of `{ id, displayName, lastUsedDate?, useCount?,
isRunning? }` objects, while `getState()` returns `{ apps }`. Observation
methods emit their result by default; pass
`{ emit: false }` when code needs the value but the model does not need to see
it. Use `nodeRepl.write(value)` for extra text and
`await nodeRepl.emitImage(image)` for extra images.

Snapshot options use camelCase and map to the native tool arguments:
`textLimit`, `maxTreeNodes`, `maxTreeDepth`, and `windowPlacement`. Keyboard
options accept `keyMethod`. For example, one macOS session can park a window,
operate on it without taking foreground focus, and restore every window parked
for that app:

```js
var chrome = await cua.getApp("Google Chrome");
await chrome.getAXState({ windowPlacement: "agent_display" });
await chrome.typeText("hello", { keyMethod: "sky_key" });
await chrome.pressKey("cmd+a", { keyMethod: "sky_key" });
await chrome.getAXState({ windowPlacement: "restore" });
```

`windowPlacement` and `keyMethod: "sky_key"` are macOS-only native
capabilities. A parked window is also restored when the MCP/REPL connection
closes or the host reports the end of the assistant turn.

Top-level bindings persist across calls. Prefer `var` for reusable names, or use
`js_reset` when the session really needs a fresh lexical scope. Resetting the
REPL does not close applications or erase their UI state.

A thrown exception ends the `js` call with `isError: true` and the message;
bindings survive. Only a timeout resets the session. Errors and output belong to
the call whose code produced them: a timer or promise callback from a call that
has already returned cannot fail or write into a later call; its late error is
dropped.

## Read-back

The native action tools normally settle for ~150 ms and return a fresh
snapshot after every action. The adapter discards that result and reads state
explicitly, so it launches the native runtime with
`OPEN_COMPUTER_USE_ACTION_READ_BACK=0`: actions return a short status with no
settle and no snapshot, and one `getAXState()` at the end of a batch reads the
outcome. On macOS a ten-click batch drops from several seconds to roughly one
state read. Linux also honors this switch; Windows keeps reading back after each
action. `selectText` still verifies the value and applied range, without taking a
full snapshot.

## Entrypoints

- The Codex plugin manifest uses the REPL launcher by default, so its advertised
  model-facing surface is `js` plus `js_reset`.
- `open-computer-use mcp` remains the native compatibility surface for other MCP
  clients (11 tools on macOS, 9 on Linux/Windows).
- The npm CLI also exposes the same runtime directly:

```sh
# One evaluation, then close the Worker and native MCP child.
ocu js 'var apps = await cua.listApps({ emit: false }); nodeRepl.write(apps)'

# Read one evaluation from stdin or a file.
printf '%s' 'nodeRepl.write(6 * 7)' | ocu js -
ocu js --file ./automation.mjs

# Keep bindings for multiple terminal inputs.
ocu repl
```

`ocu js` also accepts `--timeout <milliseconds>` and `--json`. The interactive
REPL supports `.help`, `.editor` / `.end`, `.reset`, and `.exit`; when stdin is
piped, each non-empty line is evaluated in the same persistent session. Use
`nodeRepl.write(value)` for explicit output.

Use `ocu capabilities` for a human-readable preflight or
`ocu capabilities --json` for a stable structured report. The commands remain
visible in `ocu --help` even if the adapter, kernel, or native runtime is
missing; the report marks them unavailable and execution fails with the missing
component and path.

The npm entrypoint itself currently has a `#!/usr/bin/env node` shebang. Once
the launcher is running, `js` and `repl` reuse `process.execPath` and do not
look up a second `node` on PATH. A shell with no Node executable cannot start
the npm command at all; supporting that case requires a future native bootstrap
or bundled Node distribution, not dynamic command hiding.
- The adapter can be run directly for development:

```sh
node scripts/node-repl/open-computer-use-repl.mjs -- \
  ./dist/Open\ Computer\ Use.app/Contents/MacOS/OpenComputerUse mcp
```

## Security boundary

`js` is local Node.js code execution, not a constrained expression language. It
can access the local filesystem, environment, modules, and network with the
permissions of the launching process. Only enable the REPL surface for a host
whose model-code execution policy you trust. The native Computer Use calls still
apply their own password-manager denylist and explicit global-pointer gate.

The native MCP compatibility surface remains available when arbitrary
JavaScript is not an acceptable host boundary.

## Process lifecycle

| Entry | Lifetime | Persistent state |
| --- | --- | --- |
| `ocu js` | One evaluation | A Worker and native MCP child exist only for that invocation. |
| `ocu repl` | Current terminal session | JavaScript bindings and native snapshot state persist until `.reset`, `.exit`, Ctrl-D, or termination. |
| `ocu mcp` | Current stdio MCP connection | Native MCP state persists until stdin EOF or host termination. |
| Codex plugin adapter | Current plugin MCP connection | `js` bindings persist across tool calls until `js_reset` or connection shutdown. |

On macOS, these short-lived CLI layers proxy automation to the hidden
`Open Computer Use.app` permission agent. That app agent may remain resident so
future calls reuse the same permission identity; it is separate from the Node
Worker and native MCP child owned by `js` / `repl`.
