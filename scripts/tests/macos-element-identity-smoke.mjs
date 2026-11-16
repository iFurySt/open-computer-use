#!/usr/bin/env node
import assert from 'node:assert/strict';
import {spawn,spawnSync} from 'node:child_process';
import {mkdtempSync,existsSync,readFileSync,writeFileSync,rmSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
import path from 'node:path';
import {JsonLinePeer} from '../node-repl/open-computer-use-repl.mjs';
const binary=path.resolve(process.argv[2]), baseline=process.argv.includes('--baseline');
const root=mkdtempSync('/tmp/ocu-identity-'), fixtureBinary=path.join(root,'OCUIdentityFixture');
const state=()=>JSON.parse(readFileSync(path.join(root,'state.json'),'utf8'));
const text=r=>r.content.filter(c=>c.type==='text').map(c=>c.text).join('\n');
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
async function wait(test){const end=Date.now()+10000;while(!test()){assert.ok(Date.now()<end,'fixture state timeout');await sleep(30);}}
let fixture,peer;
try {
 const built=spawnSync('swiftc',[fileURLToPath(new URL('./fixtures/MacOSIdentityFixture.swift',import.meta.url)),'-o',fixtureBinary],{encoding:'utf8'});assert.equal(built.status,0,built.stderr);
 fixture=spawn(fixtureBinary,[root],{stdio:'ignore'});await wait(()=>existsSync(path.join(root,'state.json')));
 peer=new JsonLinePeer({command:binary,args:['mcp'],env:{...process.env,OPEN_COMPUTER_USE_DISABLE_APP_AGENT_PROXY:'1',OPEN_COMPUTER_USE_VISUAL_CURSOR:'0',OPEN_COMPUTER_USE_ACTION_READ_BACK:'0'}});await peer.initialize();
 const call=(name,args)=>peer.request('tools/call',{name,arguments:{app:'OCUIdentityFixture',...args}});
 let tree=await call('get_app_state',{include_screenshot:false});assert.ok(!tree.isError,text(tree));
 const index=(label)=>{const m=text(tree).match(new RegExp('(\\d+) button '+label));assert.ok(m,text(tree));return m[1];};
 const old=index('Alpha');writeFileSync(path.join(root,'command'),'swap');await wait(()=>state().applied==='swap');
 const result=await call('click',{element_index:old});await sleep(120);
 if(baseline){assert.ok(!result.isError,text(result));assert.deepEqual(state().pressed,['Beta']);console.log('Baseline: stale Alpha index pressed Beta.');}
 else {
  assert.ok(result.isError,text(result));assert.match(text(result),/get_app_state again/);assert.deepEqual(state().pressed,[]);
  tree=await call('get_app_state',{include_screenshot:false});const refreshed=await call('click',{element_index:index('Alpha')});assert.ok(!refreshed.isError,text(refreshed));await wait(()=>state().pressed.length===1);assert.deepEqual(state().pressed,['Alpha']);
  tree=await call('get_app_state',{include_screenshot:false});const field=text(tree).match(/(\d+) text field .*identity-input/);assert.ok(field,text(tree));
  for(const value of ['first','second']){const r=await call('set_value',{element_index:field[1],value});assert.ok(!r.isError,text(r));await wait(()=>state().text===value);}
  const before=state().pressed.length;writeFileSync(path.join(root,'command'),'rename');await wait(()=>state().applied==='rename');const renamed=await call('click',{element_index:index('Alpha')});assert.ok(renamed.isError,text(renamed));assert.equal(state().pressed.length,before);
  console.log('Changed/renamed identity refused without delivery; fresh observation and repeated native text writes passed.');
 }
}finally{peer?.close();if(fixture&&fixture.exitCode===null){fixture.kill();await new Promise(r=>fixture.once('exit',r));}rmSync(root,{recursive:true,force:true});}
