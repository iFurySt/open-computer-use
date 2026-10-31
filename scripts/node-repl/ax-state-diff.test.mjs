import assert from "node:assert/strict";
import test from "node:test";
import { AXStateDiff, applyAXStateDiff } from "./ax-state-diff.mjs";
import { createCuaApi } from "./open-computer-use-repl.mjs";

const tree = (body, footer = "") => `App=example (pid 7)\nWindow: "Example", App: Example.\n0 standard window\n${body}\n${footer}`;

test("round trips additions, removals, reorders, indentation, focus and selection", () => {
  const diff = new AXStateDiff();
  let state;
  for (const text of [
    tree("\t1 button Play\n\t2 text café 👍", "The focused UI element is 1 button Play."),
    tree("\t2 text café 👍\n\t\t1 button Pause\n\t3 text 中文", "Selected text: [👍]"),
    tree("\t3 text 中文", "Note: partial tree\n\n"),
    tree("", ""),
  ]) {
    const packet = JSON.parse(diff.observe(text, "same options"));
    state = applyAXStateDiff(state, packet);
    assert.equal(state.text, text);
  }
});

test("unchanged read sends no element lines or layout", () => {
  const diff = new AXStateDiff();
  const text = tree("\t1 button Play");
  diff.observe(text);
  const packet = JSON.parse(diff.observe(text));
  assert.equal(packet.type, "ax-diff");
  assert.deepEqual(packet.added, []);
  assert.deepEqual(packet.changed, []);
  assert.deepEqual(packet.removed, []);
  assert.equal(packet.layout, undefined);
});

test("window changes, option changes, resets and duplicate indexes return full snapshots", () => {
  const diff = new AXStateDiff();
  const text = tree("\t1 button Play");
  assert.equal(JSON.parse(diff.observe(text, "a")).type, "ax-full");
  assert.equal(JSON.parse(diff.observe(text, "b")).type, "ax-full");
  assert.equal(JSON.parse(diff.observe(text.replace('"Example"', '"Other"'), "b")).type, "ax-full");
  diff.reset();
  assert.equal(JSON.parse(diff.observe(text, "b")).type, "ax-full");
  const duplicate = tree("\t1 button Play\n\t1 text repeated index");
  assert.equal(applyAXStateDiff(null, JSON.parse(diff.observe(duplicate))).text, duplicate);
  assert.equal(JSON.parse(diff.observe(duplicate)).type, "ax-full");
});

test("a missing delta cannot silently corrupt a later snapshot", () => {
  const diff = new AXStateDiff();
  const initial = applyAXStateDiff(null, JSON.parse(diff.observe(tree("\t1 text one"))));
  diff.observe(tree("\t1 text two"));
  const later = JSON.parse(diff.observe(tree("\t1 text three")));
  assert.throws(() => applyAXStateDiff(initial, later), /baseline mismatch/);
});

test("200 deterministic mixed snapshots reconstruct byte for byte", () => {
  const diff = new AXStateDiff();
  let state, seed = 17;
  const random = () => (seed = (seed * 1664525 + 1013904223) >>> 0);
  for (let step = 0; step < 200; step++) {
    const lines = [];
    for (let index = 1; index <= 25; index++) {
      if (random() % 4) lines.push(`${"\t".repeat(random() % 5)}${index} text ${random() % 7} 👍`);
    }
    if (random() % 2) lines.reverse();
    const text = tree(lines.join("\n"), `Selected text: [${step % 11}]\nNote ${step % 3}`);
    state = applyAXStateDiff(state, JSON.parse(diff.observe(text)));
    assert.equal(state.text, text);
  }
});

test("app API keeps full text by default, scopes diffs and resets after errors", async () => {
  const calls = [];
  let text = tree("\t1 button Play"), fail = false;
  const native = { async request(_method, params) {
    calls.push(params);
    if (fail) throw new Error("read failed");
    return { content: [{ type: "text", text }] };
  } };
  const api = createCuaApi(native, () => ({ write() {}, async emitImage() {} }));
  const app = await api.getApp("Example", { initialState: false });
  assert.equal(await app.getAXState({ emit: false }), text);
  let packet = JSON.parse(await app.getAXState({ diff: true, emit: false }));
  let state = applyAXStateDiff(null, packet);
  text = tree("\t1 button Pause\n\t2 text new");
  packet = JSON.parse(await app.getAXState({ diff: true, emit: false }));
  assert.equal(packet.type, "ax-diff");
  state = applyAXStateDiff(state, packet);
  assert.equal(state.text, text);
  assert.equal(JSON.parse(await app.getAXState({ diff: true, maxTreeNodes: 99, emit: false })).type, "ax-full");
  assert.equal(await app.getAXState({ diff: true, disableDiffing: true, emit: false }), text);
  assert.equal(JSON.parse(await app.getAXState({ diff: true, emit: false })).type, "ax-full");
  fail = true;
  await assert.rejects(app.getAXState({ diff: true, emit: false }), /read failed/);
  fail = false;
  assert.equal(JSON.parse(await app.getAXState({ diff: true, emit: false })).type, "ax-full");
  await assert.rejects(app.getAXState({ diff: "yes" }), /boolean/);
  assert.ok(calls.every(call => !("diff" in call.arguments) && !("disableDiffing" in call.arguments)));
});

test("mixed tab and space indentation still produces indexed element changes", () => {
  const diff = new AXStateDiff();
  diff.observe(tree(" 1 group\n\t 2 button Play"));
  const packet = JSON.parse(diff.observe(tree(" 1 group\n\t 2 button Pause\n\t 3 text new")));
  assert.deepEqual(packet.changed.map(x => x.index), [2]);
  assert.deepEqual(packet.added.map(x => x.index), [3]);
  assert.equal(packet.changed[0].text, "\t 2 button Pause");
});
