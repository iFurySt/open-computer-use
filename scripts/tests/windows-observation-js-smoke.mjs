#!/usr/bin/env node
// The PowerShell desktop smoke owns this fixture and its lifecycle.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { JsonLinePeer, WorkerJavaScriptSession } from "../node-repl/open-computer-use-repl.mjs";

const [nativePath, app, stateFile] = process.argv.slice(2);
const native = new JsonLinePeer({ command: nativePath, args: ["mcp"], env: process.env });
let session;
async function run(code, expectedError) {
  const result = await session.run(code, 20000);
  const text = result.content.filter(item => item.type === "text").map(item => item.text).join("\n");
  assert.equal(!!result.isError, !!expectedError, text);
  if (expectedError) assert.match(text, expectedError);
  return result;
}
try {
  await native.initialize();
  session = new WorkerJavaScriptSession({ native });
  const ax = await run(`var app = await cua.getApp(${JSON.stringify(app)}, {initialState:false});
    var state = await app.getAXState({includeScreenshot:false});
    function inputIndex(state) {
      var line = state.split("\\n").find(line => /^\\s*\\d+\\s+[^\\r\\n]+? Observation input(?:\\s|$)/.test(line));
      if(!line) throw Error("Fixture input not found in AX");
      return line.match(/^\\s*(\\d+)/)[1];
    }
    var oldIndex = inputIndex(state);`);
  assert.equal(ax.content.some(item => item.type === "image"), false);
  const screenshot = await run("await app.getScreenshot({includeAX:false});");
  assert.equal(screenshot.content.filter(item => item.type === "image").length, 1);
  await run('await app.setValue(oldIndex, "must-not-write");', /unknown element_index/);
  await run(`var state = await app.getAXState({includeScreenshot:false,emit:false});
    await app.setValue(inputIndex(state), "worker-live-中文");`);
  const deadline = Date.now() + 8000;
  while (JSON.parse(readFileSync(stateFile, "utf8")).text !== "worker-live-中文") {
    assert.ok(Date.now() < deadline, "Real Windows text did not update");
    await new Promise(resolve => setTimeout(resolve, 50));
  }
  const full = await run("await app.getAXStateAndScreenshot();");
  assert.equal(full.content.filter(item => item.type === "image").length, 1);
  assert.ok(full.content.some(item => item.type === "text" && item.text.includes("worker-live-中文")));
  console.log("Windows Worker JS → native MCP → WPF: channels, stale-index errors, Unicode update and default full observation passed.");
} finally {
  await session?.close();
  native.close();
}
