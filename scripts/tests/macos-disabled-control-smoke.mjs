#!/usr/bin/env node
// Real AppKit controls; pass an OCU executable with Accessibility access.
import assert from 'node:assert/strict';
import {spawn, spawnSync} from 'node:child_process';
import {mkdtempSync, existsSync, readFileSync, writeFileSync, rmSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
import path from 'node:path';
import {JsonLinePeer} from '../node-repl/open-computer-use-repl.mjs';

const root = mkdtempSync('/tmp/ocu-disabled-');
const binary = path.resolve(process.argv[2]);
const baseline = process.argv.includes('--baseline');
const fixtureBinary = path.join(root, 'OCUDisabledFixture');
const state = () => JSON.parse(readFileSync(path.join(root, 'state.json'), 'utf8'));
const text = r => r.content.filter(c => c.type === 'text').map(c => c.text).join('\n');
async function wait(test) {
  const deadline = Date.now() + 10000;
  while (!test()) {
    assert.ok(Date.now() < deadline, 'fixture state timeout');
    await new Promise(r => setTimeout(r, 30));
  }
}
let fixture, peer;
try {
  const built = spawnSync('swiftc', [fileURLToPath(new URL('./fixtures/MacOSDisabledFixture.swift', import.meta.url)), '-o', fixtureBinary], {encoding: 'utf8'});
  assert.equal(built.status, 0, built.stderr);
  fixture = spawn(fixtureBinary, [root], {stdio: 'ignore'});
  await wait(() => existsSync(path.join(root, 'state.json')));
  peer = new JsonLinePeer({command: binary, args: ['mcp'], env: {...process.env,
    OPEN_COMPUTER_USE_DISABLE_APP_AGENT_PROXY: '1', OPEN_COMPUTER_USE_VISUAL_CURSOR: '0',
    OPEN_COMPUTER_USE_ACTION_READ_BACK: '0', OPEN_COMPUTER_USE_CONFIG_FILE: path.join(root, 'config.json')}});
  await peer.initialize();
  const call = (name, args) => peer.request('tools/call', {name, arguments: {app: 'OCUDisabledFixture', ...args}});
  const tree = await call('get_app_state', {include_screenshot: false});
  assert.ok(!tree.isError, text(tree));
  const button = text(tree).match(/(\d+) button Disabled target/)?.[1];
  const slider = text(tree).match(/(\d+) slider .*disabled-slider/)?.[1];
  assert.ok(button && slider, text(tree));
  const press = () => call('click', {element_index: button, click_method: 'accessibility'});
  const increment = () => call('perform_secondary_action', {element_index: slider, action: 'Increment'});
  for (const action of [press, increment]) {
    const result = await action();
    if (baseline) assert.ok(!result.isError, text(result));
    else { assert.ok(result.isError, text(result)); assert.match(text(result), /is disabled, so nothing was sent/); }
  }
  assert.equal(state().clicks, 0); assert.equal(state().value, 20);
  if (baseline) console.log('Baseline reproduced: disabled button and slider reported success without changing state.');
  else {
    // Keep the disabled snapshot: the action must consult live AXEnabled.
    writeFileSync(path.join(root, 'command'), 'enable'); await wait(() => state().applied === 'enable');
    const pressed = await press(); assert.ok(!pressed.isError, text(pressed)); await wait(() => state().clicks === 1);
    const incremented = await increment(); assert.ok(!incremented.isError, text(incremented)); await wait(() => state().value > 20);
    // Observe enabled, then disable without refreshing: the converse must refuse too.
    await call('get_app_state', {include_screenshot: false});
    writeFileSync(path.join(root, 'command'), 'disable'); await wait(() => state().applied === 'disable');
    const before = state();
    for (const action of [press, increment]) { const r = await action(); assert.ok(r.isError, text(r)); assert.match(text(r), /is disabled/); }
    assert.equal(state().clicks, before.clicks); assert.equal(state().value, before.value);
    console.log('Disabled AppKit button/slider refused; live re-enable and disable after observation verified.');
  }
} finally {
  peer?.close();
  if (fixture && fixture.exitCode === null) { fixture.kill(); await new Promise(r => fixture.once('exit', r)); }
  rmSync(root, {recursive: true, force: true});
}
