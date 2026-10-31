#!/usr/bin/env node
// Requires a normally signed OCU executable with existing AX/Screen Recording permissions.
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync, mkdirSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { JsonLinePeer } from '../node-repl/open-computer-use-repl.mjs';
assert.equal(process.platform, 'darwin');
assert.ok(process.argv[2], 'Pass the signed OCU executable');
// Column view also exposes ancestor directories; avoid macOS's large per-user cache tree.
const directory = mkdtempSync(path.join('/tmp', 'ocu-sheet-'));

const stateFile = path.join(directory, 'state.json');
const commandFile = path.join(directory, 'command.txt');
const fixturePath = path.join(directory, 'OCUSheetFixture');
const files = path.join(directory, 'files');
mkdirSync(files);
writeFileSync(path.join(files, 'sample.txt'), 'Fixture-only file.');
const env = { ...process.env, OPEN_COMPUTER_USE_DISABLE_APP_AGENT_PROXY:'1',
  OPEN_COMPUTER_USE_DEBUG_INPUT_FALLBACKS:'1', OPEN_COMPUTER_USE_VISUAL_CURSOR:'0', OPEN_COMPUTER_USE_ACTION_READ_BACK:'0',
  OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS:'0',
  OPEN_COMPUTER_USE_CONFIG_FILE:path.join(directory, 'config.json') };
for (const key of Object.keys(env)) if (key.startsWith('OPEN_COMPUTER_USE_IMAGE_')) delete env[key];
const state = () => JSON.parse(readFileSync(stateFile, 'utf8'));
const text = result => result.content.filter(x => x.type === 'text').map(x => x.text).join('\n');
const sleep = ms => new Promise(r => setTimeout(r, ms));
let fixture, native, serial = 0;
async function waitFor(test) {
  const deadline = Date.now() + 10000;
  while (!test()) { assert.ok(Date.now() < deadline, 'Fixture state timeout'); await sleep(40); }
}
async function call(name, args, error = false) {
  if (process.argv.includes('--verbose')) console.log(name, args);
  const result = await native.request('tools/call', {name, arguments:{app:'OCUSheetFixture', ...args}});
  assert.equal(!!result.isError, error, text(result));
  return result;
}
try {
  const build = spawnSync('swiftc', [fileURLToPath(new URL('./fixtures/MacOSSheetFixture.swift', import.meta.url)), '-o', fixturePath], {encoding:'utf8'});
  assert.equal(build.status, 0, build.stderr);
  fixture = spawn(fixturePath, [stateFile, commandFile, files], {stdio:'ignore'});
  await waitFor(() => existsSync(stateFile));
  native = new JsonLinePeer({command:path.resolve(process.argv[2]), args:['mcp'], env});
  await native.initialize();
  for (const mode of ['custom', 'filtered', 'plain', 'modal']) {
    for (const method of ['snapshot', 'query', 'coordinate']) {
      const cap = method === 'coordinate' ? 300 : 4096;
      writeFileSync(env.OPEN_COMPUTER_USE_CONFIG_FILE, JSON.stringify({image:{maxLongEdgePixels:cap}}));
      const completed = state().completed;
      writeFileSync(commandFile, `open:${mode}:${++serial}`);
      await waitFor(() => state().visible);
      await sleep(700);
      const axOnly = method === 'query';
      const snapshot = await call('get_app_state', {include_screenshot:!axOnly});
      const tree = text(snapshot);
      if (process.argv.includes('--verbose')) console.log(tree);
      assert.doesNotMatch(tree, /Parent-only content/, 'Snapshot still roots at the underlying window');
      const cancel = tree.split('\n').find(line => /\bbutton Cancel\b/.test(line));
      assert.ok(cancel, tree);
      const receiver = state();
      if (mode === 'filtered') assert.equal(receiver.parentIncludesPanel, false);
      if (mode === 'plain') assert.equal(receiver.parentIncludesPanel, true);
      assert.notEqual(receiver.windowID, receiver.parentID);
      const png = snapshot.content.find(x => x.type === 'image');
      let width, height;
      if (!axOnly) {
        assert.ok(png, tree);
        const buffer = Buffer.from(png.data, 'base64');
        width = buffer.readUInt32BE(16); height = buffer.readUInt32BE(20);
        const scale = Math.min(receiver.scale, cap/Math.max(...receiver.size));
        assert.ok(Math.abs(width-receiver.size[0]*scale) <= 2 && Math.abs(height-receiver.size[1]*scale) <= 2,
          `Screenshot ${width}x${height} differs from panel ${receiver.size} at scale ${scale}`);
      } else assert.equal(png, undefined);
      // A sheet/window index must never select a descendant such as Cancel.
      {
        const rootIndex = tree.match(/^\s*(\d+)\s+(?:sheet|dialog|standard window)\b/m)?.[1];
        assert.ok(rootIndex, tree);
        for (const click_method of ['auto', 'accessibility']) {
          const result = await native.request('tools/call', {name:'click', arguments:{app:'OCUSheetFixture', element_index:rootIndex, click_method}});
          // AXRaise/focus can be unsupported. Refusal is safe; activating content is not.
          if (result.isError) assert.match(text(result), /accessibility|click|action/i);
          await sleep(250);
          assert.equal(state().completed, completed, 'Clicking the root dismissed its panel');
          assert.equal(state().open, true, 'Clicking the root selected panel content');
        }
      }
      if (method === 'query') {
        const queried = JSON.parse(text(await call('query', {role:'AXButton', text:'Cancel', exact:true})));
        assert.equal(queried.matches.length, 1, JSON.stringify(queried));
        assert.equal(queried.window_id, receiver.windowID, JSON.stringify(queried));
        const index = queried.matches[0].index;
        await call('click', {element_index:index, click_method:'accessibility'});
        await waitFor(() => state().completed === completed + 1);
        const stale = await call('click', {element_index:index, click_method:'accessibility'}, true);
        assert.match(text(stale), /no longer|not a current|expired|changed|unavailable/i);
      } else if (method === 'coordinate') {
        const queried = JSON.parse(text(await call('query', {role:'AXButton', text:'Cancel', exact:true})));
        assert.equal(queried.matches.length, 1);
        assert.equal(queried.window_id, receiver.windowID);
        const {x,y,w,h} = queried.matches[0].bounds;
        await call('click', {x:(x+w/2)*width/receiver.size[0], y:(y+h/2)*height/receiver.size[1]});
      } else {
        await call('click', {element_index:cancel.trim().split(/\s/)[0], click_method:'accessibility'});
      }
      await waitFor(() => state().completed === completed + 1);
      assert.equal(state().response, 0, 'Panel must be cancelled, never accept a file');
      await sleep(200);
      const parent = await call('get_app_state', {include_screenshot:false});
      assert.match(text(parent), /Parent-only content/);
      console.log(JSON.stringify({mode, method, panel:receiver.size, screenshot:png ? [width,height] : null, passed:true}));
    }
  }
  console.log('Real NSOpenPanel/native MCP smoke passed. Global pointer fallback disabled; foreground/pointer stability not asserted on active desktop.');
} catch (error) {
  console.error(native?.stderr);
  if (existsSync(stateFile)) console.error(state());
  throw error;
} finally {
  native?.close();
  if (fixture && fixture.exitCode === null) {
    fixture.kill('SIGTERM');
    await new Promise(resolve => { const timer=setTimeout(()=>{fixture.kill('SIGKILL');resolve();},2000); fixture.once('exit',()=>{clearTimeout(timer);resolve();}); });
  }
  rmSync(directory,{recursive:true,force:true});
}
