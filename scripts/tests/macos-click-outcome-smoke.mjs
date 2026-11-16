#!/usr/bin/env node
// Only fixture buttons are pressed. Run against baseline and patched signed apps.
import assert from 'node:assert/strict';
import {spawn, spawnSync} from 'node:child_process';
import {mkdtempSync, existsSync, readFileSync, rmSync} from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {JsonLinePeer} from '../node-repl/open-computer-use-repl.mjs';
const binary = path.resolve(process.argv[2]);
const baseline = process.argv.includes('--expect-repeat');
const root = mkdtempSync('/tmp/ocu-click-outcome-');
const stateFile = path.join(root,'state.json');
const fixtureBinary = path.join(root,'OCUSlowClickFixture');
const sleep = ms => new Promise(r=>setTimeout(r,ms));
const state = () => JSON.parse(readFileSync(stateFile,'utf8'));
const text = r => r.content.filter(c=>c.type==='text').map(c=>c.text).join('\n');
let fixture, peer;
try {
  const build = spawnSync('swiftc',[fileURLToPath(new URL('./fixtures/MacOSSlowClickFixture.swift',import.meta.url)),'-o',fixtureBinary],{encoding:'utf8'});
  assert.equal(build.status,0,build.stderr);
  fixture = spawn(fixtureBinary,[stateFile],{stdio:'ignore'});
  const deadline=Date.now()+10000;
  while(!existsSync(stateFile)){assert.ok(Date.now()<deadline,'fixture startup');await sleep(30);}
  peer=new JsonLinePeer({command:binary,args:['mcp'],env:{...process.env,
    OPEN_COMPUTER_USE_DISABLE_APP_AGENT_PROXY:'1',OPEN_COMPUTER_USE_VISUAL_CURSOR:'0',
    OPEN_COMPUTER_USE_ACTION_READ_BACK:'0',OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS:'0'}});
  await peer.initialize();
  const call=(name,args)=>peer.request('tools/call',{name,arguments:{app:'OCUSlowClickFixture',...args}});
  const snapshot=await call('get_app_state',{include_screenshot:false});
  assert.ok(!snapshot.isError,text(snapshot));
  const index=label=>{const match=text(snapshot).match(new RegExp('(\\d+) button '+label));assert.ok(match,text(snapshot));return match[1];};
  for(let round=0;round<3;round++) {
    const before=state().slow;
    const start=Date.now();
    const result=await call('click',{element_index:index('Slow action')});
    const elapsed=Date.now()-start;
    await sleep(2500); // permit the handler and any incorrectly queued fallback to finish
    const delta=state().slow-before;
    if(baseline) assert.ok(delta>1,`baseline did not reproduce duplicate action: ${delta}`);
    else {assert.equal(delta,1,'click repeated');assert.equal(result.isError,true);assert.match(text(result),/may have acted/);}
    console.log(`Slow action round ${round+1}: deliveries=${delta}, responseMs=${elapsed}, error=${!!result.isError}`);
  }
  const before=state().fast;
  const fast=await call('click',{element_index:index('Fast action')});
  assert.ok(!fast.isError,text(fast));await sleep(150);assert.equal(state().fast,before+1);
  const double=await call('click',{element_index:index('Fast action'),click_count:2});
  assert.ok(!double.isError,text(double));await sleep(150);assert.equal(state().fast,before+3);
  console.log('Fast single and intentional double clicks delivered exactly once/twice.');
} finally {
  peer?.close();
  if(fixture && fixture.exitCode===null){fixture.kill();await new Promise(resolve=>fixture.once('exit',resolve));}
  rmSync(root,{recursive:true,force:true});
}
