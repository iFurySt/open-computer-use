# Targeted query (macOS)

Find controls by text or role without a screenshot or a full AX tree. The app must already be running. Query does not launch, activate or raise it.

Use a persistent MCP session or `ocu repl`:

```js
var safari = await cua.getApp("Safari", { initialState: false });
var result = await safari.query({ text: "Compose", role: "button", exact: true });
nodeRepl.write(result);
```

After checking the result, act on its index in the same session:

```js
if (!result.truncated && result.matches.length === 1) {
  await safari.click(result.matches[0].index);
}
```

`getApp()` still reads initial state by default. Set `initialState: false` to skip it.

For inspection from the CLI:

```sh
ocu call query --args '{"app":"Safari","text":"Compose","role":"button","exact":true}'
```

Separate CLI calls cannot share indexes. Handles expire after 120 seconds, with at most 5000 retained in one native session. Query again after reset or session end. Actions revalidate the app process, window, control and current geometry; failed validation never falls back to cached coordinates.

## Options and results

Provide at least one of `text` and `role`. When both are present, both must match. Text matches title, description, value, tooltip (`AXHelp`) or identifier without case sensitivity. A control with no text of its own matches the text it holds, as the screen shows it: a web result drawn as one-letter texts (`R`, `S`, `I`, blank, `S`…) matches `RSI Strategy`, and the match's title is that text. Only the smallest such control matches, not its containers. Roles accept either `button` or `AXButton`.

| JS option | Native option | Default | Meaning |
| --- | --- | --- | --- |
| `text` | `text` | None | Control text, at most 1000 UTF-16 code units |
| `role` | `role` | None | AX role, at most 1000 UTF-16 code units |
| `exact` | `exact` | `false` | Match the whole text; otherwise use a substring. An exact miss never retries as a substring |
| `limit` | `limit` | `20` | Positive result limit, capped at 100 |
| `maxNodes` | `max_nodes` | `500` | Positive traversal/queue budget, capped at 5000 |
| `windowId` | `window_id` | Current window | An app window ID, from 1 through 4294967295 |

The result contains `matches`, `truncated`, `stop_reason`, `visited_nodes`, `window_id` and the effective `limit` / `max_nodes`. Each match includes `index` and the available role, title, value, identifier, window-relative bounds and actions.

`truncated: true` means the search is incomplete. An empty `matches` array then does not establish that the control is absent. Reasons are `limit`, `max_nodes`, `timeout`, `ax_error` and `text_limit`; a complete search reports `complete`. Long text is searched only within a bounded prefix, and output text is capped at 1000 characters. Reaching the result limit conservatively marks the search incomplete.

Traversal has a two-second cooperative deadline and per-call AX messaging timeouts. The deadline cannot forcibly interrupt an in-flight system call. Results depend on the app's exposed AX controls; unrendered rows and controls outside the window may be absent. Windows and Linux do not support query yet.
