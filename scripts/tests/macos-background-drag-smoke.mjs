#!/usr/bin/env node
// Opt-in real AppKit/MCP test. Briefly activates a test-only covering window;
// do not type or move the mouse during the run. Never enables global input.
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { JsonLinePeer } from '../node-repl/open-computer-use-repl.mjs';

assert.equal(process.platform, 'darwin');
assert.ok(process.argv[2], 'Pass an OCU executable with AX and Screen Recording permissions');
const root = mkdtempSync('/tmp/ocu-background-drag-');
const nativePath = path.resolve(process.argv[2]);
const baseline = process.argv.includes('--expect-baseline');
const verbose = process.argv.includes('--verbose');
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const text = r => r.content.filter(c => c.type === 'text').map(c => c.text).join('\n');
const state = role => JSON.parse(readFileSync(path.join(root, `${role}.json`), 'utf8'));
const env = { ...process.env, OPEN_COMPUTER_USE_DISABLE_APP_AGENT_PROXY: '1',
  OPEN_COMPUTER_USE_VISUAL_CURSOR: '0', OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS: '0',
  OPEN_COMPUTER_USE_ACTION_READ_BACK: '1', OPEN_COMPUTER_USE_CONFIG_FILE: path.join(root, 'config.json') };
for (const key of Object.keys(env)) if (key.startsWith('OPEN_COMPUTER_USE_IMAGE_')) delete env[key];
writeFileSync(env.OPEN_COMPUTER_USE_CONFIG_FILE, JSON.stringify({ image: { maxLongEdgePixels: 900 } }));
let native;
const children = [];
let serial = 0;
async function waitFor(test, message) {
  const deadline = Date.now() + 10000;
  while (!test()) { assert.ok(Date.now() < deadline, message); await sleep(40); }
}
function launch(role) {
  const name = role === 'target' ? 'OCUDragTarget' : 'OCUDragForeground';
  const app = path.join(root, `${name}.app`, 'Contents');
  mkdirSync(path.join(app, 'MacOS'), { recursive: true });
  copyFileSync(path.join(root, 'fixture'), path.join(app, 'MacOS', name));
  writeFileSync(path.join(app, 'Info.plist'), `<?xml version="1.0" encoding="UTF-8"?>
    <plist version="1.0"><dict><key>CFBundleIdentifier</key><string>dev.ocu.${name}</string>
    <key>CFBundleExecutable</key><string>${name}</string><key>CFBundleName</key><string>${name}</string>
    <key>CFBundlePackageType</key><string>APPL</string></dict></plist>`);
  const child = spawn(path.join(app, 'MacOS', name), [path.join(root, `${role}.json`), path.join(root, `${role}.command`), role], { stdio: 'ignore' });
  children.push(child);
  return child;
}
async function reset(role) {
  const command = `reset:${++serial}`;
  writeFileSync(path.join(root, `${role}.command`), command);
  await waitFor(() => state(role).command === command, `Reset ${role}`);
}
async function call(name, args) {
  const result = await native.request('tools/call', { name, arguments: { app: 'dev.ocu.OCUDragTarget', ...args } });
  assert.equal(!!result.isError, false, text(result));
  return result;
}
try {
  const build = spawnSync('swiftc', [fileURLToPath(new URL('./fixtures/MacOSDragFixture.swift', import.meta.url)), '-o', path.join(root, 'fixture')], { encoding: 'utf8' });
  assert.equal(build.status, 0, build.stderr);
  launch('target');
  await waitFor(() => existsSync(path.join(root, 'target.json')), 'Target launch');
  launch('foreground');
  await waitFor(() => existsSync(path.join(root, 'foreground.json')) && state('foreground').active && state('foreground').key && state('foreground').fieldFocused, 'Foreground fixture focus');
  native = new JsonLinePeer({ command: nativePath, args: ['mcp'], env });
  await native.initialize();
  const before = state('foreground');
  assert.equal(before.frontPID, before.pid);
  assert.ok(before.windowOrder.indexOf(before.windowID) < before.windowOrder.indexOf(state('target').windowID), 'Target must be covered');
  // Initial window registration/capture can settle asynchronously. Only retry
  // observation here, never a drag or another state-changing operation.
  await sleep(300);
  let snapshot, png;
  for (let attempt = 0; attempt < 3; attempt++) {
    snapshot = await call('get_app_state', {});
    png = snapshot.content.find(c => c.type === 'image');
    if (png) break;
    await sleep(100);
  }
  assert.ok(png, text(snapshot));
  const bytes = Buffer.from(png.data, 'base64');
  // Both ends lie well below the text field and inside the canvas.
  const width = bytes.readUInt32BE(16), height = bytes.readUInt32BE(20);
  const args = { from_x: width * .2, from_y: height * .4, to_x: width * .75, to_y: height * .75 };
  await reset('target'); await reset('foreground');
  const result = await call('drag', args);
  await sleep(300);
  const target = state('target'), after = state('foreground');
  if (verbose) console.log(JSON.stringify({ args, result: text(result), target, foreground: after }, null, 2));
  if (baseline) {
    assert.equal(target.path.length, 0, 'Baseline unexpectedly drew: investigate instead of assuming failure');
    console.log('Reproduced: native app_post drag returned without any canvas stroke.');
  } else {
    const kinds = target.events.map(e => e.kind);
    assert.deepEqual(kinds, ['down', ...Array(10).fill('dragged'), 'up'], 'Exactly one complete drag, no primer or duplicate delivery');
    assert.ok(target.path.length >= 3, 'The actual canvas must have a stroke');
    assert.ok(target.renderedSegments > 0, 'The canvas draw callback must render the received stroke');
    assert.ok(target.events.every(e => e.windowID === target.windowID), 'All events must target the same window');
    const start = target.path[0], end = target.path.at(-1);
    assert.ok(end[0] - start[0] > 200 && end[1] - start[1] > 80, `Wrong stroke coordinates: ${start} -> ${end}`);
    assert.equal(target.active, false, 'Synthetic activation must be released');
    assert.equal(target.key, false, 'Synthetic key state must be released');
  }
  assert.equal(after.active, true);
  assert.equal(after.key, true);
  assert.equal(after.fieldFocused, true);
  assert.equal(after.text, before.text);
  assert.equal(after.activationLosses, before.activationLosses, 'No transient foreground activation loss');
  assert.equal(after.keyLosses, before.keyLosses, 'No transient foreground key loss');
  assert.deepEqual(after.observedFrontPIDs, [after.pid], 'Foreground PID changed during input');
  assert.ok(after.maxPointerMovement < .5, 'Real pointer moved (user activity also fails this check)');
  assert.ok(after.windowOrder.indexOf(after.windowID) < after.windowOrder.indexOf(target.windowID), 'Target window was raised');
  console.log(JSON.stringify({ passed: true, baseline, eventCount: target.events.length, points: target.path.length,
    foregroundStable: true, maxPointerMovement: after.maxPointerMovement }));
  if (!baseline) {
    const expectRefusal = async (coordinates, pattern) => {
      const count = state('target').events.length;
      const refused = await native.request('tools/call', { name: 'drag', arguments: { app: 'dev.ocu.OCUDragTarget', ...coordinates } });
      assert.equal(refused.isError, true, text(refused));
      assert.match(text(refused), pattern);
      await sleep(100);
      assert.equal(state('target').events.length, count, 'Refused drag must send no input');
      assert.equal(state('foreground').activationLosses, before.activationLosses);
      assert.equal(state('foreground').keyLosses, before.keyLosses);
    };
    await expectRefusal({ ...args, from_x: -1 }, /inside.*window/i);
    await expectRefusal({ ...args, to_x: width + 1 }, /inside.*window/i);
    const move = `move:${++serial}`;
    writeFileSync(path.join(root, 'target.command'), move);
    await waitFor(() => state('target').command === move, 'Move target');
    await sleep(300);
    await expectRefusal(args, /window moved/i);
    // Refreshing explicitly is required after a geometry change.
    await call('get_app_state', {});
    const close = `close:${++serial}`;
    writeFileSync(path.join(root, 'target.command'), close);
    await waitFor(() => state('target').command === close && !state('target').visible, 'Close target');
    // WindowServer may retain the closing window while its frame shrinks for
    // the close animation. Either identity loss or geometry loss must refuse.
    await expectRefusal(args, /window disappeared|window moved|unavailable/i);
    console.log('Invalid coordinates, moved window and closed window refused without extra input or foreground focus loss.');
    // Explicit fixture setup for the compatibility case, not part of drag:
    // reopen/activate our own target, then verify normal drag does not send a
    // synthetic deactivation to an app that was already truly foreground.
    const activate = `activate:${++serial}`;
    writeFileSync(path.join(root, 'target.command'), activate);
    await waitFor(() => state('target').command === activate && state('target').active && state('target').key, 'Foreground target');
    await sleep(300);
    await reset('target');
    const frontBefore = state('target');
    const frontSnapshot = await call('get_app_state', {});
    const frontPNG = frontSnapshot.content.find(c => c.type === 'image');
    assert.ok(frontPNG, text(frontSnapshot));
    const frontBytes = Buffer.from(frontPNG.data, 'base64');
    const fw = frontBytes.readUInt32BE(16), fh = frontBytes.readUInt32BE(20);
    await call('drag', { from_x: fw * .2, from_y: fh * .4, to_x: fw * .75, to_y: fh * .75 });
    await sleep(200);
    const frontAfter = state('target');
    assert.deepEqual(frontAfter.events.map(e => e.kind), ['down', ...Array(10).fill('dragged'), 'up']);
    assert.ok(frontAfter.renderedSegments > 0);
    assert.equal(frontAfter.active, true);
    assert.equal(frontAfter.key, true);
    assert.equal(frontAfter.frontPID, frontAfter.pid);
    assert.equal(frontAfter.activationLosses, frontBefore.activationLosses);
    assert.equal(frontAfter.keyLosses, frontBefore.keyLosses);
    assert.ok(frontAfter.maxPointerMovement < .5);
    console.log('Already-foreground target also receives one gesture without synthetic deactivation or real-pointer movement.');
  }
} catch (error) {
  console.error(native?.stderr);
  for (const role of ['target', 'foreground']) if (existsSync(path.join(root, `${role}.json`))) console.error(role, state(role));
  throw error;
} finally {
  native?.close();
  for (const child of children.reverse()) {
    if (child.exitCode !== null) continue;
    child.kill('SIGTERM');
    await Promise.race([new Promise(resolve => child.once('exit', resolve)), sleep(1500)]);
    if (child.exitCode === null) child.kill('SIGKILL');
  }
  rmSync(root, { recursive: true, force: true });
}
