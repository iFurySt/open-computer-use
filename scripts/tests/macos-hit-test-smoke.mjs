#!/usr/bin/env node
// Real AppKit receiver; pass an OCU executable with Accessibility/Screen Recording access.
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, writeFileSync, existsSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { JsonLinePeer } from '../node-repl/open-computer-use-repl.mjs';
// Active desktops cannot establish whether foreground/pointer changes came from the test.
const allowDesktopActivity = process.argv.includes('--allow-desktop-activity');
const descendantGuards = process.argv.includes('--descendant-guards');
const root = mkdtempSync(path.join(tmpdir(), 'ocu-hit-test-'));
const statePath = path.join(root, 'state.json');
const fixturePath = path.join(root, 'OCUHitTestFixture');
const nativePath = path.resolve(process.argv[2] ?? '.build/debug/OpenComputerUse');
const env = { ...process.env, OPEN_COMPUTER_USE_DISABLE_APP_AGENT_PROXY: '1',
  OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS: '0',
  OPEN_COMPUTER_USE_VISUAL_CURSOR: '0', OPEN_COMPUTER_USE_DEBUG_INPUT_FALLBACKS:'1', OPEN_COMPUTER_USE_ACTION_READ_BACK: '0',
  OPEN_COMPUTER_USE_CONFIG_FILE: path.join(root, 'config.json') };
for (const key of Object.keys(env)) if (key.startsWith('OPEN_COMPUTER_USE_IMAGE_')) delete env[key];
const state = () => JSON.parse(readFileSync(statePath, 'utf8'));
const text = result => result.content.filter(x => x.type === 'text').map(x => x.text).join('\n');
let fixture, native;
async function waitFor(test) {
  const until = Date.now() + 5000;
  while (!test()) { assert.ok(Date.now() < until, 'Receiver did not observe the expected click'); await new Promise(r => setTimeout(r, 30)); }
}
async function call(name, args, error = false) {
  const result = await native.request('tools/call', { name, arguments: { app: 'OCUHitTestFixture', ...args } });
  assert.equal(!!result.isError, error, text(result));
  return result;
}
try {
  const build = spawnSync('swiftc', [fileURLToPath(new URL('./fixtures/MacOSHitTestFixture.swift', import.meta.url)), '-o', fixturePath], {encoding:'utf8'});
  assert.equal(build.status, 0, build.stderr);
  fixture = spawn(fixturePath, [statePath, ...(descendantGuards ? ['--descendant-guards'] : [])], {stdio:'ignore'});
  await waitFor(() => existsSync(statePath));
  await new Promise(r => setTimeout(r, 500));
  const initial = state();
  native = new JsonLinePeer({command:nativePath,args:['mcp'],env});
  await native.initialize();
  for (const cap of [4096, 300, null]) {
    writeFileSync(env.OPEN_COMPUTER_USE_CONFIG_FILE, JSON.stringify({image:{maxLongEdgePixels:cap ?? 4096}}));
    const result = await call('get_app_state', {include_screenshot:cap !== null});
    const match = text(result).match(/^\s*(\d+)\s+[^\n]*Hit target row/m);
    assert.ok(match, text(result));
    if (descendantGuards) {
      const untouched = state();
      if (cap !== null) {
        const png = Buffer.from(result.content.find(x => x.type === 'image').data, 'base64');
        await call('click', {x:500*png.readUInt32BE(16)/untouched.windowSize[0], y:330*png.readUInt32BE(20)/untouched.windowSize[1]});
        await new Promise(r => setTimeout(r, 150));
        assert.equal(state().closeAttempts, 0, 'Blank coordinate click pressed Close');
        assert.equal(state().wrongClicks, untouched.wrongClicks, 'Blank coordinate click pressed another button');
      }
      const windowIndex = text(result).match(/^\s*(\d+)\s+dialog OCU Hit Test Fixture/m)?.[1];
      assert.ok(windowIndex, text(result));
      for (const method of ['auto', 'accessibility']) {
        await call('click', {element_index:windowIndex, click_method:method});
        await new Promise(r => setTimeout(r, 100));
        assert.equal(state().closeAttempts, 0, 'Window-index click pressed Close');
        assert.equal(state().wrongClicks, untouched.wrongClicks, 'Window-index click pressed its contents');
      }
    }
    const before = state();
    native.stderr = '';
    await call('click', {element_index:match[1]});
    await new Promise(r => setTimeout(r, 100));
    const hit = native.stderr.match(/hit test window=\(([^,]+), ([^)]+)\) screen=\(([^,]+), ([^)]+)\) result=0/);
    assert.ok(hit, native.stderr);
    assert.ok(Math.abs(Number(hit[3])-before.screenPoint[0]) < 2 && Math.abs(Number(hit[4])-before.screenPoint[1]) < 2,
      `AX hit test missed the target: ${hit[0]} expected ${before.screenPoint}`);
    assert.equal(state().wrongClicks, before.wrongClicks, 'Hit test pressed the unrelated button');
    if (descendantGuards) assert.equal(state().closeAttempts, 0, 'Row click pressed Close');
    const image = result.content.find(x => x.type === 'image');
    if (cap !== null) {
      assert.ok(image, text(result));
      const png = Buffer.from(image.data, 'base64');
      const width = png.readUInt32BE(16), height = png.readUInt32BE(20);
      if (cap === 300) assert.equal(Math.max(width,height), 300);
      else assert.ok(width > initial.windowSize[0], 'Retina coverage requires a >1x screenshot');
      console.log(JSON.stringify({cap, screenshot:[width,height], window:initial.windowSize, indexedHitTest:'passed'}));
      native.stderr = '';
      await call('click', {x:before.buttonPoint[0]*width/before.windowSize[0], y:before.buttonPoint[1]*height/before.windowSize[1]});
      await waitFor(() => state().wrongClicks === before.wrongClicks + 1);
      const coordinateHit = native.stderr.match(/screen=\(([^,]+), ([^)]+)\) result=0/);
      assert.ok(coordinateHit, native.stderr);
      assert.ok(Math.abs(Number(coordinateHit[1])-before.buttonScreenPoint[0]) < 2 && Math.abs(Number(coordinateHit[2])-before.buttonScreenPoint[1]) < 2,
        'Screenshot coordinates were converted more than once');

    } else {
      assert.equal(image, undefined);
      const refusal = await call('click', {x:10,y:10}, true);
      assert.match(text(refusal), /screenshot/i);
      console.log('AX-only indexed hit test passed; screenshot-coordinate click correctly refused');
    }
    // A real AXPress receiver verifies that actions actually reach this fixture.
    const button = text(result).match(/^\s*(\d+)\s+button Wrong target/m);
    assert.ok(button);
    const beforeControl = state().wrongClicks;
    await call('click', {element_index:button[1], click_method:'accessibility'});
    await waitFor(() => state().wrongClicks === beforeControl + 1);
    // Explicit window-index clicks may raise/focus the window by design.
    if (!allowDesktopActivity) {
      assert.equal(state().frontPID, descendantGuards ? before.frontPID : initial.frontPID, 'Foreground app changed during control clicks');
      assert.deepEqual(state().pointer, initial.pointer, 'Physical pointer moved');
    }
  }
  if (descendantGuards) {
    const full = await call('get_app_state', {});
    const closeLine = text(full).split('\n').find(line => /close/i.test(line) && /button/.test(line));
    assert.ok(closeLine, text(full));
    await call('click', {element_index:closeLine.trim().split(/\s/)[0], click_method:'accessibility'});
    await waitFor(() => state().closeAttempts === 1);
    console.log('Blank points, actionless row, window indexes and explicit Close passed.');
  }
  if (allowDesktopActivity) console.log('Desktop activity allowed: foreground/pointer stability was not asserted.');
  console.log('Real AppKit/native MCP hit-test smoke passed.');
} finally {
  native?.close();
  if (fixture && fixture.exitCode === null) {
    fixture.kill('SIGTERM');
    await new Promise(resolve => { const timer=setTimeout(()=>{fixture.kill('SIGKILL');resolve();},2000); fixture.once('exit',()=>{clearTimeout(timer);resolve();}); });
  }
  rmSync(root,{recursive:true,force:true});
}
