#!/usr/bin/env node
// A real AppKit receiver and native MCP. Requires an authorized, signed OCU executable.
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, writeFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { setTimeout as sleep } from 'node:timers/promises';
import { JsonLinePeer } from '../node-repl/open-computer-use-repl.mjs';

const binary = path.resolve(process.argv[2]);
const expectRegression = process.argv.includes('--expect-regression');
const root = mkdtempSync(path.join(tmpdir(), 'ocu-snapshot-geometry-'));
const fixturePath = path.join(root, 'OCUSnapshotGeometryFixture');
const config = path.join(root, 'config.json');
const env = { ...process.env, OPEN_COMPUTER_USE_DISABLE_APP_AGENT_PROXY: '1',
  OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS: '0', OPEN_COMPUTER_USE_VISUAL_CURSOR: '0',
  OPEN_COMPUTER_USE_ACTION_READ_BACK: '0', OPEN_COMPUTER_USE_CONFIG_FILE: config };
for (const key of Object.keys(env)) if (key.startsWith('OPEN_COMPUTER_USE_IMAGE_')) delete env[key];
const text = result => result.content.filter(c => c.type === 'text').map(c => c.text).join('\n');
const state = () => JSON.parse(readFileSync(path.join(root, 'state.json'), 'utf8'));
const results = [];
let fixture, peer;
async function waitFor(predicate) {
  const until = Date.now() + 5000;
  while (!predicate()) { assert.ok(Date.now() < until, 'Fixture timeout'); await sleep(30); }
}
async function call(name, args = {}) {
  const result = await peer.request('tools/call', { name, arguments: { app: 'OCUSnapshotGeometryFixture', ...args } });
  assert.ok(!result.isError, text(result));
  return result;
}
async function mode(value) {
  writeFileSync(path.join(root, 'command'), value);
  await waitFor(() => state().mode === value);
  await sleep(300);
}
async function check(name, run) {
  try { const detail = await run(); results.push({ name, passed: true, ...detail }); }
  catch (error) { results.push({ name, passed: false, error: error.message.slice(0, 1500) }); }
  console.log(JSON.stringify(results.at(-1)));
}
try {
  const build = spawnSync('swiftc', [fileURLToPath(new URL('./fixtures/MacOSSnapshotGeometryFixture.swift', import.meta.url)), '-o', fixturePath], { encoding: 'utf8' });
  assert.equal(build.status, 0, build.stderr);
  fixture = spawn(fixturePath, [root], { stdio: 'ignore' });
  await waitFor(() => existsSync(path.join(root, 'state.json')));
  peer = new JsonLinePeer({ command: binary, args: ['mcp'], env });
  await peer.initialize();
  for (const placement of ['normal', 'right-offscreen', 'left-offscreen']) {
    await mode(placement);
    for (const cap of [4096, 300]) await check(`${placement}-${cap}`, async () => {
      writeFileSync(config, JSON.stringify({ image: { format: 'png', maxLongEdgePixels: cap, scaleDownAfterMaxSize: true } }));
      const started = performance.now();
      const result = await call('get_app_state', { text_limit: 'max' });
      const durationMs = Math.round(performance.now() - started);
      writeFileSync(path.join(root, `${placement}-${cap}.txt`), text(result));
      const image = result.content.find(c => c.type === 'image');
      assert.ok(image, text(result));
      const png = Buffer.from(image.data, 'base64');
      const screenshot = path.join(root, `${placement}-${cap}.png`);
      writeFileSync(screenshot, png);
      const width = png.readUInt32BE(16), height = png.readUInt32BE(20);
      const before = state(), [ww, wh] = before.windowSize;
      assert.ok(Math.abs(width - height * ww / wh) <= 2, `Cropped screenshot: ${width}x${height}, window ${ww}x${wh}`);
      if (cap === 300) assert.equal(Math.max(width, height), 300);
      const pixels = spawnSync(fixturePath, ['--pixels', screenshot, ...[100, 300, 500].flatMap(x => [String(x / ww), String(before.markerY / wh)])], { encoding: 'utf8' });
      assert.equal(pixels.status, 0, pixels.stderr);
      const colors = JSON.parse(pixels.stdout);
      colors.forEach((rgb, index) => {
        assert.ok(rgb[index] > 220 && rgb.filter((_, i) => i !== index).every(v => v < 65),
          `Missing/misaligned marker ${index}: ${rgb}`);
      });
      const side = placement === 'left-offscreen' ? 'right' : 'left';
      const [x, y] = before[`${side}Point`];
      await call('click', { x: x * width / ww, y: y * height / wh });
      await waitFor(() => state()[`${side}Clicks`] === before[`${side}Clicks`] + 1);
      const other = side === 'left' ? 'right' : 'left';
      assert.equal(state()[`${other}Clicks`], before[`${other}Clicks`]);
      return { screenshot: [width, height], window: [ww, wh], colors, click: side, durationMs };
    });
  }
  for (const invalid of ['bad-position', 'bad-size']) await check(invalid, async () => {
    await mode(invalid);
    const result = await call('get_app_state', { include_screenshot: false, text_limit: 'max' });
    writeFileSync(path.join(root, `${invalid}.txt`), text(result));
    assert.match(text(result), /Invalid geometry probe/);
    const query = JSON.parse(text(await call('query', { text: 'Invalid geometry probe' })));
    assert.equal(query.matches.length, 1);
    assert.equal(query.matches[0].bounds, undefined, 'Invalid query geometry must be omitted');
    const button = text(result).match(/^\s*(\d+) button Left target/m)?.[1];
    assert.ok(button, text(result));
    const before = state().leftClicks;
    await call('click', { element_index: button, click_method: 'accessibility' });
    await waitFor(() => state().leftClicks === before + 1);
    await mode('normal');
    assert.match(text(await call('get_app_state', { include_screenshot: false })), /Left target/);
    return { subsequentReadAndClick: 'passed' };
  });
  writeFileSync(path.join(root, 'results.json'), JSON.stringify(results, null, 2));
  const failures = results.filter(result => !result.passed);
  if (expectRegression) {
    assert.ok(results.filter(r => r.name.startsWith('normal')).every(r => r.passed), 'Baseline control failed');
    assert.ok(failures.some(r => r.name.includes('offscreen')), 'Baseline did not reproduce offscreen cropping');
    assert.ok(failures.some(r => r.name.startsWith('bad-')), 'Baseline did not reproduce invalid AX geometry');
  }
  else assert.deepEqual(failures, [], 'Snapshot geometry regression');
} finally {
  peer?.close();
  if (fixture?.exitCode === null) {
    fixture.kill('SIGTERM'); await sleep(200);
    if (fixture.exitCode === null) fixture.kill('SIGKILL');
  }
  console.log(`Fixture evidence: ${root}`);
}
