#!/usr/bin/env node
// Compare cached/uncached real AppKit AX output and timing, then verify a live action.
import assert from 'node:assert/strict';
import {spawn,spawnSync} from 'node:child_process';
import {mkdtempSync,readFileSync,existsSync,rmSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
import path from 'node:path';
import {JsonLinePeer} from '../node-repl/open-computer-use-repl.mjs';
const root=mkdtempSync('/tmp/ocu-ax-batch-');
const binary=path.resolve(process.argv[2]);
const fixturePath=path.join(root,'OCUAXBatchFixture'), state=path.join(root,'state.json');
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
const env={...process.env,OPEN_COMPUTER_USE_DISABLE_APP_AGENT_PROXY:'1',OPEN_COMPUTER_USE_VISUAL_CURSOR:'0',
  OPEN_COMPUTER_USE_ACTION_READ_BACK:'0',OPEN_COMPUTER_USE_CONFIG_FILE:path.join(root,'config.json')};
const peers=[];let fixture;
const text=result=>result.content.filter(c=>c.type==='text').map(c=>c.text).join('\n');
async function call(peer,name,args) {
  const result=await peer.request('tools/call',{name,arguments:{app:'OCUAXBatchFixture',...args}});
  assert.ok(!result.isError,text(result));return text(result);
}
async function waitFor(predicate){const until=Date.now()+5000;while(!predicate()){assert.ok(Date.now()<until,'Fixture timeout');await sleep(30);}}
try {
  const build=spawnSync('swiftc',[fileURLToPath(new URL('./fixtures/MacOSAXBatchFixture.swift',import.meta.url)),'-o',fixturePath],{encoding:'utf8'});
  assert.equal(build.status,0,build.stderr);
  fixture=spawn(fixturePath,[state],{stdio:'ignore'});await waitFor(()=>existsSync(state));
  for(const disabled of ['1','0']) {
    const peer=new JsonLinePeer({command:binary,args:['mcp'],env:{...env,OPEN_COMPUTER_USE_DISABLE_AX_READ_CACHE:disabled}});
    peers.push(peer);await peer.initialize();
  }
  const durations=[[],[]];let reference;
  if(process.argv[3]) {
    const baseline=new JsonLinePeer({command:path.resolve(process.argv[3]),args:['mcp'],env});
    peers.push(baseline);await baseline.initialize();
    reference=await call(baseline,'get_app_state',{include_screenshot:false,text_limit:'max'});
  }
  // Interleave modes to reduce warm-up/order bias; ignore the first pair.
  for(let round=0;round<6;round++)for(const index of round%2?[1,0]:[0,1]) {
    const start=performance.now();
    const output=await call(peers[index],'get_app_state',{include_screenshot:false,text_limit:'max'});
    if(round>0)durations[index].push(performance.now()-start);
    assert.match(output,/Item 299/);
    if(reference===undefined)reference=output;else assert.equal(output,reference,'Batching changed AX output');
  }
  const target=reference.match(/^\s*(\d+) button Item 0(?:\s|$)/m)?.[1];assert.ok(target,reference);
  await call(peers[1],'click',{element_index:target,click_method:'accessibility'});
  await waitFor(()=>JSON.parse(readFileSync(state,'utf8')).clicks===1);
  const fresh=await call(peers[1],'get_app_state',{include_screenshot:false,text_limit:'max'});
  assert.match(fresh,/Changed 1/);assert.doesNotMatch(fresh,/button Item 0(?:\s|$)/m);
  assert.equal(fresh,await call(peers[0],'get_app_state',{include_screenshot:false,text_limit:'max'}));
  const median=values=>[...values].sort((a,b)=>a-b)[Math.floor(values.length/2)];
  console.log(JSON.stringify({uncachedMedianMs:median(durations[0]),cachedMedianMs:median(durations[1]),samples:durations}));
  console.log('300 real AppKit controls: identical full AX output, live indexed click and fresh subsequent state passed.');
} finally {
  for(const peer of peers)peer.close();
  if(fixture?.exitCode===null){fixture.kill('SIGTERM');await sleep(200);if(fixture.exitCode===null)fixture.kill('SIGKILL');}
  rmSync(root,{recursive:true,force:true});
}
