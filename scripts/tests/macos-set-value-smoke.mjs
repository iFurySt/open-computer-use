#!/usr/bin/env node
// Uses only fixture-owned text, real AppKit controls and the ordinary native/JS/CLI entry points.
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { JsonLinePeer, WorkerJavaScriptSession } from '../node-repl/open-computer-use-repl.mjs';
assert.equal(process.platform, 'darwin');
assert.ok(process.argv[2], 'Pass the normally signed OCU executable');
const nativePath = path.resolve(process.argv[2]);
const root = mkdtempSync('/tmp/ocu-set-value-');
const statePath = path.join(root, 'state.json');
const commandPath = path.join(root, 'command.json');
const fixturePath = path.join(root, 'OCUTextInputFixture');
const appName = 'OCUTextInputFixture';
const env = {...process.env, OPEN_COMPUTER_USE_DISABLE_APP_AGENT_PROXY:'1',
  OPEN_COMPUTER_USE_DEBUG_INPUT_FALLBACKS:'1', OPEN_COMPUTER_USE_VISUAL_CURSOR:'0', OPEN_COMPUTER_USE_ACTION_READ_BACK:'0',
  OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS:'0', OPEN_COMPUTER_USE_CONFIG_FILE:path.join(root,'config.json')};
writeFileSync(env.OPEN_COMPUTER_USE_CONFIG_FILE, '{}');
const state = () => JSON.parse(readFileSync(statePath, 'utf8'));
const text = result => result.content.filter(x => x.type === 'text').map(x => x.text).join('\n');
const sleep = ms => new Promise(r => setTimeout(r, ms));
let native, fixture, worker, serial = 0, fixtureErrors = '';
async function waitFor(predicate) {
  const deadline = Date.now() + 5000;
  while (!predicate()) { assert.ok(Date.now() < deadline, `Fixture timeout: ${existsSync(statePath) ? JSON.stringify(state()) : fixtureErrors}`); await sleep(30); }
}
async function configure(args) {
  writeFileSync(commandPath, JSON.stringify({serial:++serial,...args}));
  await waitFor(() => state().serial === serial);
  await sleep(80);
}
async function call(name, args, error = false) {
  const result = await native.request('tools/call', {name,arguments:{app:appName,...args}});
  assert.equal(!!result.isError, error, text(result));
  return result;
}
async function observe() { await call('get_app_state', {include_screenshot:false}); }
async function reset(args = {}) {
  await configure({reset:true,target:'view',selection:[0,5],...args});
  await observe();
}
async function expectView(value, selection) {
  // The fixture publishes on a timer; one sample can precede the final caret write.
  await waitFor(() => {
    const snapshot = state();
    return snapshot.view === value && (!selection || snapshot.selection.every((v,i) => v === selection[i]));
  });
}
try {
  const build = spawnSync('swiftc', [fileURLToPath(new URL('./fixtures/MacOSTextInputFixture.swift', import.meta.url)), '-o',fixturePath], {encoding:'utf8'});
  assert.equal(build.status,0,build.stderr);
  fixture = spawn(fixturePath,[statePath,commandPath],{stdio:['ignore','ignore','pipe']});
  fixture.stderr.on('data',data=>{fixtureErrors+=data.toString();});
  await waitFor(()=>existsSync(statePath));
  for (const readBack of ['0', '1']) {
    native = new JsonLinePeer({command:nativePath,args:['mcp'],env:{...env,OPEN_COMPUTER_USE_ACTION_READ_BACK:readBack}});
    await native.initialize();
    for (const item of [
      {mode:'normal',value:' \t中文🙂\n'}, {mode:'normal',value:''},
      {mode:'normal',value:'hello world'}, {mode:'delay',value:'delayed'},
      {mode:'ignore',value:'new',error:true}, {mode:'trim',value:' padded ',error:true},
      {mode:'numeric',value:'0015',error:true},
    ].filter(item => !process.argv.includes('--ignored-only') || item.mode === 'ignore')) {
      await configure({reset:true,target:'view',valueMode:item.mode});
      const snapshot=await call('get_app_state',{include_screenshot:false});
      const index=text(snapshot).match(/^\s*(\d+) .*Document input/m)?.[1];
      assert.ok(index,text(snapshot));
      const result=await call('set_value',{element_index:index,value:item.value},!!item.error);
      if(item.error) assert.match(text(result),/could not verify/);
      else await expectView(item.value);
      await waitFor(()=>state().valueWrites===1);
      assert.equal(state().selectedWrites,0);
      console.log(JSON.stringify({readBack,mode:item.mode,expectedError:!!item.error,passed:true}));
    }
    native.close();native=null;
  }
  // The public JS wrapper must reject a failed native write too.
  await configure({reset:true,target:'view',valueMode:'ignore'});
  native = new JsonLinePeer({command:nativePath,args:['mcp'],env});await native.initialize();
  worker = new WorkerJavaScriptSession({native});
  const result=await worker.run(`var app=await cua.getApp("${appName}"); var state=await app.getAXState({includeScreenshot:false}); var index=state.match(/^\\s*(\\d+) .*Document input/m)[1]; await app.setValue(index,"must fail");`);
  assert.ok(result.isError,JSON.stringify(result));
  console.log('Real AppKit/native MCP set_value verification and JS rejection passed.');
} finally {
  await worker?.close();native?.close();
  if(fixture?.exitCode===null){fixture.kill();await sleep(200);if(fixture.exitCode===null)fixture.kill('SIGKILL');}
  rmSync(root,{recursive:true,force:true});
}
