#!/usr/bin/env node
// Real NSOpenPanel with an owned large directory; signed native executable required.
import assert from 'node:assert/strict';
import {spawn,spawnSync} from 'node:child_process';
import {mkdtempSync,mkdirSync,writeFileSync,readFileSync,existsSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {fileURLToPath} from 'node:url';
import path from 'node:path';
import {JsonLinePeer} from '../node-repl/open-computer-use-repl.mjs';
const root=mkdtempSync(path.join(tmpdir(),'ocu-tree-budget-'));
const files=path.join(root,'files');mkdirSync(files);
for(let i=0;i<2000;i++)writeFileSync(path.join(files,`budget-${String(i).padStart(4,'0')}.txt`),'fixture');
const statePath=path.join(root,'state.json'),commandPath=path.join(root,'command.txt');
const state=()=>JSON.parse(readFileSync(statePath,'utf8'));
const text=r=>r.content.filter(c=>c.type==='text').map(c=>c.text).join('\n');
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
const env={...process.env,OPEN_COMPUTER_USE_DISABLE_APP_AGENT_PROXY:'1',OPEN_COMPUTER_USE_VISUAL_CURSOR:'0',OPEN_COMPUTER_USE_ACTION_READ_BACK:'0',OPEN_COMPUTER_USE_CONFIG_FILE:path.join(root,'config.json')};
let native,fixture;
async function waitFor(test){const end=Date.now()+10000;while(!test()){assert.ok(Date.now()<end,'Fixture timeout');await sleep(40);}}
try {
  const executable=path.join(root,'OCUSheetFixture');
  const build=spawnSync('swiftc',[fileURLToPath(new URL('./fixtures/MacOSSheetFixture.swift',import.meta.url)),'-o',executable],{encoding:'utf8'});
  assert.equal(build.status,0,build.stderr);
  fixture=spawn(executable,[statePath,commandPath,files],{stdio:'ignore'});await waitFor(()=>existsSync(statePath));
  native=new JsonLinePeer({command:path.resolve(process.argv[2]),args:['mcp'],env});await native.initialize();
  for(const budget of [1200,40]) {
    const completed=state().completed;
    writeFileSync(commandPath,`open:modal:${budget}`);await waitFor(()=>state().visible);await sleep(800);
    const started=performance.now();
    const result=await native.request('tools/call',{name:'get_app_state',arguments:{app:'OCUSheetFixture',include_screenshot:false,max_tree_nodes:budget}});
    const tree=text(result);assert.ok(!result.isError,tree);
    const cancel=tree.match(/^\s*(\d+) button Cancel\b/m)?.[1];
    assert.ok(cancel,`Cancel missing at budget ${budget}: ${tree.slice(0,1200)}`);
    assert.match(tree,/button.*Choose test file/);
    const count=[...tree.matchAll(/^\s*\d+ /gm)].length;assert.ok(count<=budget);
    const action=await native.request('tools/call',{name:'click',arguments:{app:'OCUSheetFixture',element_index:cancel,click_method:'accessibility'}});
    assert.ok(!action.isError,text(action));await waitFor(()=>state().completed===completed+1);
    console.log(JSON.stringify({budget,rendered:count,elapsedMs:performance.now()-started,cancelReached:true}));
  }
  console.log('Real large-directory NSOpenPanel: action buttons retained and indexed Cancel reached the receiver.');
} finally {
  native?.close();if(fixture?.exitCode===null){fixture.kill();await sleep(200);if(fixture.exitCode===null)fixture.kill('SIGKILL');}
  rmSync(root,{recursive:true,force:true});
}
