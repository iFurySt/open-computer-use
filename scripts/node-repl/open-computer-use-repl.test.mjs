import assert from "node:assert/strict";
import test from "node:test";
import { EventEmitter } from "node:events";
import { PassThrough } from "node:stream";
import { JsonLinePeer, PersistentJavaScriptSession, WorkerJavaScriptSession, parseListApps, toolDefinitions, computerUseGuidance, virtualDisplayEnabled } from "./open-computer-use-repl.mjs";

function textResult(text, isError = false, image) {
  const content = [{ type: "text", text }];
  if (image) content.push({ type: "image", mimeType: image.mimeType, data: image.data });
  return { content, isError };
}

function mockNative() {
  const calls = [];
  const native = {
    calls,
    async request(method, params) {
      assert.equal(method, "tools/call");
      calls.push(params);
      switch (params.name) {
        case "list_apps": return textResult('[{"id":"com.example.Text","displayName":"Text"}]');
        case "get_app_state": return textResult(`state:${params.arguments.app}`, false, { mimeType: "image/png", data: Buffer.from([0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a]).toString("base64") });
        case "click": return textResult("clicked");
        case "type_text": return params.arguments.text === "fail" ? textResult("typing failed", true) : textResult("typed");
        default: return textResult(params.name);
      }
    },
  };
  return native;
}

test("advertises only js and js_reset", () => {
  assert.deepEqual(toolDefinitions().map(tool => tool.name), ["js", "js_reset"]);
  assert.deepEqual(toolDefinitions()[0].inputSchema.required, ["code"]);
  assert.equal(toolDefinitions()[0].inputSchema.properties.timeout_ms.maximum, 300_000);
});

test("normalizes native app-list text across macOS, Linux, and Windows", () => {
  assert.deepEqual(parseListApps([
    "TextEdit — com.apple.TextEdit [frontmost, running, last-used=2026-09-22, uses=42]",
    "Google Chrome — com.google.Chrome [last-used=2026-09-21, uses=7]",
  ].join("\n")), [
    { id: "com.apple.TextEdit", displayName: "TextEdit", isRunning: true, lastUsedDate: "2026-09-22", useCount: 42 },
    { id: "com.google.Chrome", displayName: "Google Chrome", lastUsedDate: "2026-09-21", useCount: 7 },
  ]);
  assert.deepEqual(parseListApps("gedit -- gedit [running, pid=42, window=Draft, notes]"), [
    { id: "gedit", displayName: "gedit", isRunning: true },
  ]);
  assert.deepEqual(parseListApps("No running top-level apps are visible to this Linux runtime."), []);
});

test("cua.listApps returns structured apps for the native text protocol", async () => {
  const native = mockNative();
  native.request = async (method, params) => {
    assert.equal(method, "tools/call");
    native.calls.push(params);
    return textResult("TextEdit — com.apple.TextEdit [running, last-used=2026-09-22, uses=4]");
  };
  const session = new PersistentJavaScriptSession({ native });
  const result = await session.run(`
    var apps = await cua.listApps({ emit: false });
    nodeRepl.write(JSON.stringify(apps));
  `);
  assert.equal(result.isError, false);
  assert.deepEqual(JSON.parse(result.content.at(-1).text), [
    { id: "com.apple.TextEdit", displayName: "TextEdit", isRunning: true, lastUsedDate: "2026-09-22", useCount: 4 },
  ]);
});

test("top-level await and lexical bindings persist until reset", async () => {
  const session = new PersistentJavaScriptSession({ native: mockNative() });
  let result = await session.run("var answer = await Promise.resolve(41); nodeRepl.write(answer);");
  assert.equal(result.isError, false);
  assert.equal(result.content.at(-1).text, "41");
  result = await session.run("answer += 1; nodeRepl.write(answer);");
  assert.equal(result.content.at(-1).text, "42");
  session.reset();
  result = await session.run("nodeRepl.write(typeof answer);");
  assert.equal(result.content.at(-1).text, "undefined");
});

test("return values are not implicitly serialized into MCP output", async () => {
  const session = new PersistentJavaScriptSession({ native: mockNative() });
  const result = await session.run("({ huge: 'intermediate-only' })");
  assert.equal(result.isError, false);
  assert.equal(result.content.at(-1).text, "(no output)");
});

test("app-bound API composes actions and state in one js call", async () => {
  const native = mockNative();
  const session = new PersistentJavaScriptSession({ native });
  const result = await session.run(`
    var app = await cua.getApp("Text");
    await app.click(7, { clickMethod: "accessibility" });
    await app.typeText("hello");
    await app.getAXState();
  `);
  assert.equal(result.isError, false);
  assert.deepEqual(native.calls.map(call => call.name), ["get_app_state", "click", "type_text", "get_app_state"]);
  assert.equal(native.calls[1].arguments.element_index, 7);
  assert.equal(native.calls[1].arguments.click_method, "accessibility");
  assert.ok(result.content.some(item => item.type === "text" && item.text === "state:Text"));
});

for (const Session of [PersistentJavaScriptSession, WorkerJavaScriptSession]) {
  test(`${Session.name}: AX getter skips capture by default while screenshot/combined getters keep their arguments`, async t => {
    const native = mockNative();
    const session = new Session({ native });
    t.after(() => session.close?.());
    const result = await session.run(`
      var selectiveApp = await cua.getApp("Text", { initialState: false });
      await selectiveApp.getScreenshot({ includeAX: false, emit: false });
      await selectiveApp.getAXState({ includeScreenshot: false, emit: false });
      await selectiveApp.getScreenshot({ emit: false });
      await selectiveApp.getAXState({ emit: false });
    `);
    assert.equal(result.isError, false);
    assert.deepEqual(native.calls.map(call => call.arguments), [
      { app: "Text", include_ax: false, text_limit: 1 },
      { app: "Text", include_screenshot: false, text_limit: "max" },
      { app: "Text", text_limit: 1 },
      { app: "Text", include_screenshot: false, text_limit: "max" },
    ]);
    const count = native.calls.length;
    for (const code of [
      'await selectiveApp.getScreenshot({ includeAX: "false" })',
      'await selectiveApp.getAXState({ includeScreenshot: null })',
    ]) {
      const invalid = await session.run(code);
      assert.equal(invalid.isError, true);
      assert.match(invalid.content.at(-1).text, /must be a boolean/);
    }
    assert.equal(native.calls.length, count);
    const empty = await session.run('await selectiveApp.getAXStateAndScreenshot({ includeAX: false, includeScreenshot: false })');
    assert.equal(empty.isError, true);
    assert.match(empty.content.at(-1).text, /At least one/);
    assert.equal(native.calls.length, count);
  });
}

test("app-bound API forwards explicitly enabled background-operation options", async t => {
  const previous = process.env.OPEN_COMPUTER_USE_VIRTUAL_DISPLAY_ENABLED;
  process.env.OPEN_COMPUTER_USE_VIRTUAL_DISPLAY_ENABLED = "true";
  t.after(() => {
    if (previous === undefined) delete process.env.OPEN_COMPUTER_USE_VIRTUAL_DISPLAY_ENABLED;
    else process.env.OPEN_COMPUTER_USE_VIRTUAL_DISPLAY_ENABLED = previous;
  });
  if (process.platform !== "darwin") { t.skip("virtual displays are macOS-only"); return; }
  const native = mockNative();
  const session = new PersistentJavaScriptSession({ native });
  const result = await session.run(`
    var backgroundApp = await cua.getApp("Text");
    await backgroundApp.getAXState({ emit: false, textLimit: "max", maxTreeNodes: 42, maxTreeDepth: 7, windowPlacement: "agent_display" });
    await backgroundApp.getScreenshot({ emit: false, windowPlacement: "keep" });
    await backgroundApp.getAXStateAndScreenshot({ emit: false, windowPlacement: "restore" });
    await backgroundApp.typeText("hello", { keyMethod: "sky_key" });
    await backgroundApp.pressKey("cmd+a", { keyMethod: "sky_key" });
    await backgroundApp.pressKey("ctrl+a", { keyMethod: "global" });
  `);

  assert.equal(result.isError, false);
  assert.deepEqual(native.calls[1], {
    name: "get_app_state",
    arguments: {
      app: "Text",
      text_limit: "max",
      max_tree_nodes: 42,
      max_tree_depth: 7,
      window_placement: "agent_display",
      include_screenshot: false,
    },
  });
  assert.deepEqual(native.calls[2], {
    name: "get_app_state",
    arguments: { app: "Text", window_placement: "keep", text_limit: 1 },
  });
  assert.deepEqual(native.calls[3], {
    name: "get_app_state",
    arguments: { app: "Text", window_placement: "restore" },
  });
  assert.deepEqual(native.calls[4], {
    name: "type_text",
    arguments: { app: "Text", text: "hello", key_method: "sky_key" },
  });
  assert.deepEqual(native.calls[5], {
    name: "press_key",
    arguments: { app: "Text", key: "cmd+a", key_method: "sky_key" },
  });
  assert.deepEqual(native.calls[6], {
    name: "press_key",
    arguments: { app: "Text", key: "ctrl+a", key_method: "global" },
  });
});

test("tool errors are catchable in JavaScript", async () => {
  const session = new PersistentJavaScriptSession({ native: mockNative() });
  const result = await session.run(`
    var badApp = await cua.getApp("Text");
    try { await badApp.typeText("fail"); } catch (error) { nodeRepl.write("caught: " + error.message); }
  `);
  assert.equal(result.isError, false);
  assert.equal(result.content.at(-1).text, "caught: typing failed");
});

test("thrown errors settle the call and keep bindings", async () => {
  const session = new PersistentJavaScriptSession({ native: mockNative() });
  await session.run("var kept = 1;");
  let result = await session.run("nodeRepl.write('before'); null[1];", 1000);
  assert.equal(result.isError, true);
  assert.match(result.content.at(-1).text, /^Error: Cannot read properties of null/);
  result = await session.run("await 1; throw new Error('after await');", 1000);
  assert.equal(result.isError, true);
  assert.equal(result.content.at(-1).text, "Error: after await");
  result = await session.run("nodeRepl.write(kept);");
  assert.equal(result.content.at(-1).text, "1");
});

for (const Session of [PersistentJavaScriptSession, WorkerJavaScriptSession]) {
  test(`${Session.name}: a late throw from a finished call does not reach the next call`, async () => {
    const session = new Session({ native: mockNative() });
    try {
      let result = await session.run(`var kept = 1; setTimeout(() => { throw new Error("late"); }, 20);
        setTimeout(() => nodeRepl.write("late write"), 20);`, 1000);
      assert.equal(result.isError, false);
      result = await session.run(`await new Promise(resolve => setTimeout(resolve, 100)); nodeRepl.write("next " + kept);`, 1000);
      assert.deepEqual(result, { content: [{ type: "text", text: "next 1" }], isError: false });
      result = await session.run(`nodeRepl.write("after");`, 1000);
      assert.deepEqual(result, { content: [{ type: "text", text: "after" }], isError: false });
    } finally {
      await session.close?.();
    }
  });
}

test("screenshots emit binary image content", async () => {
  const session = new PersistentJavaScriptSession({ native: mockNative() });
  const result = await session.run(`
    var imageApp = await cua.getApp("Text");
    var imageBytes = await imageApp.getScreenshot();
    nodeRepl.write(imageBytes.length);
  `);
  assert.equal(result.isError, false);
  assert.ok(result.content.some(item => item.type === "image" && item.mimeType === "image/png"));
  assert.equal(result.content.at(-1).text, "8");
});

test("JsonLinePeer initializes and correlates native MCP responses", async () => {
  const child = new EventEmitter();
  child.stdout = new PassThrough(); child.stderr = new PassThrough(); child.stdin = new PassThrough();
  child.kill = () => {};
  let input = "";
  child.stdin.setEncoding("utf8");
  child.stdin.on("data", chunk => {
    input += chunk;
    for (;;) {
      const newline = input.indexOf("\n"); if (newline < 0) break;
      const request = JSON.parse(input.slice(0, newline)); input = input.slice(newline + 1);
      if (request.id !== undefined) child.stdout.write(`${JSON.stringify({ jsonrpc: "2.0", id: request.id, result: request.method === "initialize" ? { ok: true } : { content: [] } })}\n`);
    }
  });
  const peer = new JsonLinePeer({ child });
  assert.deepEqual(await peer.initialize(), { ok: true });
  assert.deepEqual(await peer.request("tools/call", { name: "list_apps" }), { content: [] });
  peer.closed = true;
});

test("worker session terminates CPU-bound code and recovers with a fresh kernel", async () => {
  const session = new WorkerJavaScriptSession({ native: mockNative() });
  let result = await session.run("while (true) {}", 100);
  assert.equal(result.isError, true);
  assert.match(result.content[0].text, /timed out/);
  result = await session.run("nodeRepl.write(21 * 2);", 5_000);
  assert.equal(result.isError, false);
  assert.equal(result.content.at(-1).text, "42");
  await session.close();
});

test("worker session returns a structured error for invalid source input", async () => {
  const session = new WorkerJavaScriptSession({ native: mockNative() });
  const result = await session.run(undefined, 5_000);
  assert.equal(result.isError, true);
  assert.match(result.content[0].text, /non-empty JavaScript source/);
  const recovered = await session.run("nodeRepl.write('ready');", 5_000);
  assert.equal(recovered.isError, false);
  assert.equal(recovered.content.at(-1).text, "ready");
  await session.close();
});

test("worker session serializes concurrent callers", async () => {
  const session = new WorkerJavaScriptSession({ native: mockNative() });
  const first = session.run("await new Promise(resolve => setTimeout(resolve, 40)); var order = ['first']; nodeRepl.write(order.join(','));", 5_000);
  const second = session.run("order.push('second'); nodeRepl.write(order.join(','));", 5_000);
  assert.equal((await first).content.at(-1).text, "first");
  assert.equal((await second).content.at(-1).text, "first,second");
  await session.close();
});

test("native session end rejects pending work and initializes a fresh child without replay", async () => {
  const source = `
    let buffer = '';
    process.stdin.setEncoding('utf8');
    process.stdin.on('data', chunk => {
      buffer += chunk;
      for (;;) {
        const end = buffer.indexOf('\\n'); if (end < 0) break;
        const request = JSON.parse(buffer.slice(0, end)); buffer = buffer.slice(end + 1);
        if (request.id === undefined || request.method === 'stall') continue;
        process.stdout.write(JSON.stringify({jsonrpc:'2.0', id:request.id, result:{pid:process.pid}}) + '\\n');
      }
    });
  `;
  const peer = new JsonLinePeer({ command: process.execPath, args: ["--input-type=module", "-e", source] });
  try {
    const first = await peer.initialize();
    const old = peer.child;
    const pending = peer.request("stall", {}, 5_000);
    const rejected = assert.rejects(pending, /session ended/);
    peer.endSession();
    await rejected;
    const next = await peer.request("ping", {}, 5_000);
    assert.notEqual(next.pid, first.pid);
    old.emit("exit", 1, null);
    assert.equal(peer.closed, false);
    await assert.rejects(peer.request("stall", {}, 20), /timed out/);
    assert.equal(peer.closed, true);
    const recovered = await peer.request("ping", {}, 5_000);
    assert.notEqual(recovered.pid, next.pid);
  } finally { peer.close(); }
});

test("worker reset and timeout end the native GUI lease", async () => {
  const native = mockNative();
  let ended = 0;
  native.endSession = () => { ended += 1; };
  const session = new WorkerJavaScriptSession({ native });
  try {
    await session.reset();
    assert.equal(ended, 1);
    const result = await session.run("while (true) {}", 100);
    assert.equal(result.isError, true);
    assert.equal(ended, 2);
  } finally { await session.close(); }
});


test("reset drops old worker native requests before a replacement kernel starts", async () => {
  const native = mockNative();
  const session = new WorkerJavaScriptSession({ native });
  try {
    const old = session.worker;
    const resetting = session.reset();
    old.emit("message", { type: "native_request", id: 1, method: "tools/call", params: { name: "click", arguments: {} } });
    await resetting;
    assert.equal(native.calls.length, 0);
    old.emit("message", { type: "native_request", id: 2, method: "tools/call", params: { name: "click", arguments: {} } });
    assert.equal(native.calls.length, 0);
  } finally { await session.close(); }
});

test("lightweight app binding queries and acts across persistent JS calls without a snapshot", async () => {
  const native = mockNative();
  const request = native.request;
  native.request = async (method, params) => {
    if (params.name !== "query") return request(method, params);
    native.calls.push(params);
    return textResult(JSON.stringify({ matches: [{ index: 1000001, title: "Send" }], truncated: false, stop_reason: "complete", visited_nodes: 3, window_id: 12 }));
  };
  const session = new PersistentJavaScriptSession({ native });
  let result = await session.run(`var queriedApp = await cua.getApp("Text", { initialState: false }); var found = await queriedApp.query({ text: "Send", role: "button", exact: true, maxNodes: 50, windowId: 12 }); nodeRepl.write(found);`);
  assert.equal(result.isError, false, result.content.at(-1).text);
  assert.deepEqual(native.calls.map(c => c.name), ["query"]);
  assert.deepEqual(native.calls[0].arguments, { app: "Text", text: "Send", role: "button", exact: true, limit: undefined, max_nodes: 50, window_id: 12 });
  result = await session.run(`await queriedApp.click(found.matches[0].index);`);
  assert.equal(result.isError, false);
  assert.equal(native.calls.at(-1).arguments.element_index, 1000001);
  assert.equal(native.calls.some(c => c.name === "get_app_state"), false);
});

test("query rejects invalid options and preserves native errors", async () => {
  const native = mockNative(), session = new PersistentJavaScriptSession({ native });
  await session.run(`var queriedApp = await cua.getApp("Text", { initialState: false });`);
  for (const options of [`{}`, `{text: "Send", windowId: -1}`, `{text: "Send", windowId: 4294967296}`, `{text: "Send", exact: 1}`, `{text: 3}`, `{role: "button", maxNodes: 1.5}`, `{text: "Send", typo: true}`]) {
    const result = await session.run(`await queriedApp.query(${options});`);
    assert.equal(result.isError, true, options);
  }
  assert.equal(native.calls.length, 0);
  native.request = async () => textResult("query is unavailable on this platform", true);
  const result = await session.run(`await queriedApp.query({text: "Send"});`);
  assert.equal(result.isError, true);
  assert.match(result.content.at(-1).text, /unavailable on this platform/);
});

test("query returns truncation metadata and rejects malformed native responses", async () => {
  const native = mockNative(), session = new PersistentJavaScriptSession({ native });
  native.request = async () => textResult(JSON.stringify({ matches: [], truncated: true, stop_reason: "timeout" }));
  const result = await session.run(`var queriedApp = await cua.getApp("Text", { initialState: false }); nodeRepl.write(JSON.stringify(await queriedApp.query({role: "button"})));`);
  assert.equal(result.isError, false);
  assert.equal(JSON.parse(result.content.at(-1).text).stop_reason, "timeout");
  native.request = async () => textResult("[]");
  const bad = await session.run(`await queriedApp.query({role: "button"});`);
  assert.equal(bad.isError, true);
  assert.match(bad.content.at(-1).text, /Invalid query response/);
});


for (const Session of [PersistentJavaScriptSession, WorkerJavaScriptSession]) {
  test(`${Session.name}: selectText forwards all selection modes without a snapshot`, async t => {
    const native = mockNative(), session = new Session({ native });
    t.after(() => session.close?.());
    let result = await session.run(`var selectionApp = await cua.getApp("Text", { initialState: false }); await selectionApp.selectText(1000001, "中文🙂", {prefix: "before ", suffix: " after"});`);
    assert.equal(result.isError, false, result.content.at(-1).text);
    assert.deepEqual(native.calls[0], { name: "select_text", arguments: { app: "Text", element_index: 1000001, text: "中文🙂", prefix: "before ", suffix: " after", selection: undefined } });
    for (const mode of ["text", "cursor_before", "cursor_after"]) {
      result = await session.run(`await selectionApp.selectText("5", "target", {selection: "${mode}"});`);
      assert.equal(result.isError, false, result.content.at(-1).text);
      assert.equal(native.calls.at(-1).arguments.selection, mode);
    }
    assert.equal(native.calls.some(call => call.name === "get_app_state"), false);
  });

  test(`${Session.name}: selectText rejects invalid inputs before native calls`, async t => {
    const native = mockNative(), session = new Session({ native });
    t.after(() => session.close?.());
    await session.run(`var selectionApp = await cua.getApp("Text", { initialState: false });`);
    for (const args of [`-1,"x"`, `1.5,"x"`, `true,"x"`, `"bad","x"`, `[],"x"`, `0,""`, `0,3`, `0,"x",null`, `0,"x",[]`, `0,"x",{prefix:2}`, `0,"x",{suffix:null}`, `0,"x",{selection:"after"}`, `0,"x",{selection:""}`, `0,"x",{typo:true}`]) {
      const result = await session.run(`await selectionApp.selectText(${args});`);
      assert.equal(result.isError, true, args);
    }
    assert.equal(native.calls.length, 0);
  });

  test(`${Session.name}: selectText preserves native verification and platform failures`, async t => {
    const native = mockNative(), session = new Session({ native });
    t.after(() => session.close?.());
    await session.run(`var selectionApp = await cua.getApp("Text", { initialState: false });`);
    for (const message of ["select_text could not verify the requested range", 'unsupportedTool("select_text")']) {
      native.request = async () => textResult(message, true);
      const result = await session.run(`await selectionApp.selectText(0,"target");`);
      assert.equal(result.isError, true);
      assert.ok(result.content.at(-1).text.includes(message), result.content.at(-1).text);
    }
  });
}


test("virtual display guidance follows explicit host configuration", () => {
  const env = { OPEN_COMPUTER_USE_CONFIG_FILE: "/nonexistent/ocu-test-config.json" };
  assert.equal(virtualDisplayEnabled(env, "darwin"), false);
  assert.doesNotMatch(computerUseGuidance(env, "darwin"), /windowPlacement/);
  const enabled = { ...env, OPEN_COMPUTER_USE_VIRTUAL_DISPLAY_ENABLED: "true" };
  assert.match(computerUseGuidance(enabled, "darwin"), /windowPlacement/);
  assert.equal(virtualDisplayEnabled({ ...enabled, OPEN_COMPUTER_USE_CONFIG_FILE: "relative" }, "darwin"), true);
  assert.equal(virtualDisplayEnabled({ ...enabled, OPEN_COMPUTER_USE_VIRTUAL_DISPLAY_ENABLED: "1" }, "darwin"), false);
  assert.doesNotMatch(computerUseGuidance(enabled, "linux"), /windowPlacement/);
  assert.doesNotMatch(computerUseGuidance(enabled, "win32"), /windowPlacement/);
});

test("disabled virtual displays reject stale JS options before native dispatch", async t => {
  const previous = process.env.OPEN_COMPUTER_USE_VIRTUAL_DISPLAY_ENABLED;
  process.env.OPEN_COMPUTER_USE_VIRTUAL_DISPLAY_ENABLED = "false";
  t.after(() => {
    if (previous === undefined) delete process.env.OPEN_COMPUTER_USE_VIRTUAL_DISPLAY_ENABLED;
    else process.env.OPEN_COMPUTER_USE_VIRTUAL_DISPLAY_ENABLED = previous;
  });
  const native = mockNative();
  const session = new PersistentJavaScriptSession({ native });
  const result = await session.run(`
    var app = await cua.getApp("Text", { initialState: false });
    await app.getAXState({ windowPlacement: "agent_display" });
  `);
  assert.equal(result.isError, true);
  assert.match(result.content.at(-1).text, /disabled by virtualDisplay.enabled/);
  assert.equal(native.calls.length, 0);
  const restored = await session.run('await app.getAXState({ windowPlacement: "restore", emit: false });');
  assert.equal(restored.isError, false);
  assert.equal(native.calls.at(-1).arguments.window_placement, "restore");
});


test("AX-only defaults preserve data and warnings while explicit capture remains available", async () => {
  const calls = [];
  const native = { async request(_method, params) {
    calls.push(params.arguments);
    return { content: [
      { type: "text", text: "App=Example\n0 window\n 1 text Screenshot omitted by include_screenshot=false" },
      { type: "text", text: "Screenshot omitted by include_screenshot=false" },
      { type: "text", text: "Note: partial tree" },
    ] };
  } };
  const session = new PersistentJavaScriptSession({ native });
  const result = await session.run(`var ax = await cua.getApp("Example", { initialState: false });
    var value = await ax.getAXState({ emit: false }); nodeRepl.write(value);
    await ax.getAXState({ includeScreenshot: true, textLimit: 500, emit: false });`);
  assert.equal(result.isError, false);
  assert.equal(result.content.at(-1).text, "App=Example\n0 window\n 1 text Screenshot omitted by include_screenshot=false\nNote: partial tree");
  assert.deepEqual(calls[0], { app: "Example", include_screenshot: false, text_limit: "max" });
  assert.deepEqual(calls[1], { app: "Example", include_screenshot: true, text_limit: 500 });
});
