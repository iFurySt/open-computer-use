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
const root = mkdtempSync('/tmp/ocu-text-input-');
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
async function expectView(value) { await waitFor(() => state().view === value); }
try {
  const build = spawnSync('swiftc', [fileURLToPath(new URL('./fixtures/MacOSTextInputFixture.swift', import.meta.url)), '-o',fixturePath], {encoding:'utf8'});
  assert.equal(build.status,0,build.stderr);
  fixture = spawn(fixturePath,[statePath,commandPath],{stdio:['ignore','ignore','pipe']});
  fixture.stderr.on('data',data=>{fixtureErrors+=data.toString();});
  await waitFor(()=>existsSync(statePath));
  native = new JsonLinePeer({command:nativePath,args:['mcp'],env});
  await native.initialize();
  await reset();
  await call('type_text',{text:'X'});
  await expectView('X world');
  console.log('Selection replacement passed.');

  await reset();
  await call('type_text',{text:''},true);
  await sleep(150);
  assert.equal(state().view,'hello world','Empty input deleted the selection');
  assert.deepEqual(state().selection,[0,5]);
  console.log('Empty native input is rejected without changing the selection.');

  await reset({text:'中🙂文e\u0301尾',selection:[1,2]});
  await call('type_text',{text:'新🚀'});
  await expectView('中新🚀文e\u0301尾');
  await call('type_text',{text:'!'});
  await expectView('中新🚀!文e\u0301尾');
  await reset({text:'中🙂文',selection:[3,0]});
  await call('type_text',{text:'<'});
  await expectView('中🙂<文');
  console.log('Unicode replacement, caret insertion and consecutive typing passed.');

  await reset();
  await configure({target:'field',text:'field',selection:[0,5]});
  await call('type_text',{text:'Y'});
  await waitFor(()=>state().field==='Y');
  assert.equal(state().view,'hello world');
  await configure({target:'sheet',selection:[0,4]});
  await call('type_text',{text:'新名'});
  await waitFor(()=>state().sheet==='新名.txt');
  assert.equal(state().view,'hello world');
  assert.equal(state().field,'Y');
  console.log('Live focus follows a field and a sheet without refreshing the snapshot.');

  await reset();
  await configure({target:'none'});
  const noFocus = await call('type_text',{text:'WRONG'},true);
  assert.match(text(noFocus),/current focused|focus/i);
  assert.equal(state().view,'hello world');
  assert.equal(state().valueWrites,0);
  assert.equal(state().selectedWrites,0);
  console.log('Unavailable live focus refuses input without using cached focus.');

  await reset({valueWritable:false});
  await call('type_text',{text:'Selected only'});
  await expectView('Selected only world');
  assert.equal(state().valueWrites,0);
  assert.equal(state().selectedWrites,1);
  console.log('AXSelectedText works without writable AXValue.');

  await reset({selectedWritable:false});
  await call('type_text',{text:'K'});
  await expectView('K world');
  assert.equal(state().valueWrites,1);
  assert.deepEqual(state().selection,[1,0]);
  await reset({selectedWritable:false,selection:[11,0]});
  await call('type_text',{text:'1'});
  await expectView('hello world1');
  await call('type_text',{text:'2'});
  await expectView('hello world12');
  await reset({selectedWritable:false,text:'中🙂文e\u0301尾',selection:[1,2]});
  await call('type_text',{text:'新🚀'});
  await expectView('中新🚀文e\u0301尾');
  assert.deepEqual(state().selection,[4,0]);
  await call('type_text',{text:'!'});
  await expectView('中新🚀!文e\u0301尾');
  console.log('Value fallback preserves selection, Unicode and caret across consecutive calls.');

  for (const failure of ['rejectValueWrite','rejectCaretWrite']) {
    await reset({selectedWritable:false,[failure]:true});
    const rejected = await call('type_text',{text:'ONCE'},true);
    assert.match(text(rejected),/before retrying/);
    await sleep(150);
    assert.equal(state().valueWrites,1);
    assert.equal(state().selectedWrites,0);
    assert.equal(state().view,failure==='rejectValueWrite' ? 'hello world' : 'ONCE world');
  }
  console.log('Value/caret write failures are reported without a second input attempt.');

  await reset();
  await configure({target:'view',rejectSelectedWrite:true,selection:[0,5]});
  const failedWrite = await call('type_text',{text:'NO RETRY'},true);
  assert.match(text(failedWrite),/AXSelectedText|before retrying/);
  await sleep(200);
  assert.equal(fixture.exitCode,null,'Failure injection must not crash the receiver');
  assert.equal(state().view,'hello world');
  assert.equal(state().selectedWrites,1,'Selected-text write was retried');
  assert.equal(state().valueWrites,0,'Failed write fell back to full-value append');
  console.log('Failed selected-text write does not append or resend.');

  await reset();
  await configure({target:'view',moveFocusOnProbe:true,selection:[0,5]});
  const changed = await call('type_text',{text:'WRONG'},true);
  assert.match(text(changed),/focus changed/i);
  assert.equal(state().view,'hello world');
  assert.equal(state().field,'untouched');
  console.log('Focus change during capability lookup is rejected before writing.');

  await reset();
  worker = new WorkerJavaScriptSession({native});
  const js = await worker.run(`var textApp = await cua.getApp(${JSON.stringify(appName)}, {initialState:false}); await textApp.typeText("JS");`);
  assert.equal(js.isError,false,text(js));
  await expectView('JS world');
  await reset();
  const cli = spawnSync(nativePath,['call','type_text','--args',JSON.stringify({app:appName,text:'CLI'})],{env,encoding:'utf8',timeout:15000});
  assert.equal(cli.status,0,cli.stderr);
  assert.equal(!!JSON.parse(cli.stdout).isError,false,cli.stdout);
  await expectView('CLI world');
  console.log('Worker JS and CLI both preserve selection semantics.');
  console.log('Real AppKit text-input smoke passed; active-desktop foreground/pointer stability not asserted.');
} catch(error) {
  await sleep(150);
  console.error(native?.stderr,fixtureErrors);
  if(existsSync(statePath)) console.error(state());
  throw error;
} finally {
  await worker?.close();
  native?.close();
  if(fixture && fixture.exitCode===null) {
    fixture.kill('SIGTERM');
    await new Promise(resolve=>{const timer=setTimeout(()=>{fixture.kill('SIGKILL');resolve();},2000);fixture.once('exit',()=>{clearTimeout(timer);resolve();});});
  }
  rmSync(root,{recursive:true,force:true});
}
