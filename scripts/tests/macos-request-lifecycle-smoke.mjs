#!/usr/bin/env node
// Signed OCU with existing macOS permissions; isolated receiver, agent and socket.
// Usage: node scripts/tests/macos-request-lifecycle-smoke.mjs <executable> [--measure-only]
import assert from 'node:assert/strict';
import {spawn, spawnSync} from 'node:child_process';
import {mkdtempSync, existsSync, rmSync} from 'node:fs';
import {createConnection} from 'node:net';
import {fileURLToPath} from 'node:url';
import path from 'node:path';
import {JsonLinePeer} from '../node-repl/open-computer-use-repl.mjs';
const root = mkdtempSync('/tmp/ocu-lifecycle-');
const binary = path.resolve(process.argv[2]);
const measureOnly = process.argv.includes('--measure-only');
const env = {...process.env, OPEN_COMPUTER_USE_DISABLE_APP_AGENT_PROXY:'1',
  OPEN_COMPUTER_USE_VISUAL_CURSOR:'0', OPEN_COMPUTER_USE_CONFIG_FILE:path.join(root,'config.json')};
const sleep = ms => new Promise(r=>setTimeout(r,ms));
const children = [], sockets = [];
let native;
function build(source, name) {
  const output=path.join(root,name);
  const r=spawnSync('swiftc',[fileURLToPath(new URL(`./fixtures/${source}`,import.meta.url)),'-o',output],{encoding:'utf8'});
  assert.equal(r.status,0,r.stderr); return output;
}
async function waitFor(predicate) {
  const deadline=Date.now()+10000;
  while (!predicate()) { assert.ok(Date.now()<deadline,'Timed out waiting for fixture/cleanup'); await sleep(50); }
}
function connect(socketPath) {
  return new Promise((resolve,reject)=>{
    const socket=createConnection(socketPath); sockets.push(socket);
    socket.once('error',reject); socket.once('connect',()=>resolve(socket));
  });
}
function request(socket, object) {
  return new Promise((resolve,reject)=>{
    let buffer=''; const timer=setTimeout(()=>done(new Error('Agent request timed out')),30000);
    const data=chunk=>{buffer+=chunk; if(buffer.includes('\n')) done(null,JSON.parse(buffer.split('\n')[0]));};
    const error=e=>done(e); const close=()=>done(new Error('Agent disconnected'));
    function done(e,value) {clearTimeout(timer);socket.off('data',data);socket.off('error',error);socket.off('close',close);e?reject(e):resolve(value);}
    socket.on('data',data); socket.on('error',error); socket.on('close',close);
    socket.write(JSON.stringify(object)+'\n');
  });
}
try {
  const probe=build('MacOSResourceProbe.swift','probe');
  const receiver=build('MacOSHitTestFixture.swift','OCUHitTestFixture');
  const fixture=spawn(receiver,[path.join(root,'state.json')],{stdio:'ignore'});children.push(fixture);
  await waitFor(()=>existsSync(path.join(root,'state.json')));
  const usage=pid=>{const r=spawnSync(probe,[String(pid)],{encoding:'utf8'});assert.equal(r.status,0,r.stderr);return JSON.parse(r.stdout);};
  const params={name:'get_app_state',arguments:{app:'OCUHitTestFixture',include_screenshot:true}};
  async function memory(label,pid,call) {
    const samples=[];
    for(let i=1;i<=100;i++) {
      const result=await call(i);
      assert.ok(!result.isError,JSON.stringify(result));
      assert.ok(result.content.some(c=>c.type==='image'),'Missing screenshot');
      if(i===20||i===100)samples.push(usage(pid).footprint);
    }
    const growthMiB=(samples[1]-samples[0])/1024/1024;
    console.log(JSON.stringify({label,samplesMiB:samples.map(n=>n/1024/1024),growthMiB}));
    if(!measureOnly)assert.ok(growthMiB<30,`${label} retains screenshot objects across requests`);
  }
  native=new JsonLinePeer({command:binary,args:['mcp'],env});await native.initialize();
  await memory('stdio',native.child.pid,()=>native.request('tools/call',params));
  native.close();
  const socketPath=path.join(root,'agent.sock');
  const agent=spawn(binary,['__open-computer-use-app-agent',socketPath],{env,stdio:'ignore'});children.push(agent);
  await waitFor(()=>existsSync(socketPath));
  const client=await connect(socketPath);
  await memory('agent',agent.pid,async id=>{
    const envelope=await request(client,{kind:'mcp',line:JSON.stringify({jsonrpc:'2.0',id,method:'tools/call',params}),environment:env});
    assert.ok(!envelope.error,envelope.error);return JSON.parse(envelope.response).result;
  });
  const start=usage(agent.pid);await sleep(3000);const end=usage(agent.pid);
  console.log(JSON.stringify({idleWakeupsPerSecond:(end.wakeups-start.wakeups)/3}));
  if(!measureOnly)assert.ok(end.wakeups-start.wakeups<12,'Idle client still polls at 10 Hz');
  // An idle close must release its descriptor; repeated connections must not accumulate.
  const unixFDs=()=>spawnSync('/usr/sbin/lsof',['-a','-p',String(agent.pid),'-U','-Fn'],{encoding:'utf8'}).stdout.split('\n').filter(l=>l.startsWith('n')).length;
  client.destroy();await sleep(200);const baselineFDs=unixFDs();
  for(let i=0;i<10;i++){const s=await connect(socketPath);await request(s,{kind:'agentInfo'});s.destroy();}
  await waitFor(()=>unixFDs()===baselineFDs);
  // Disconnect while a response is being generated/written, then verify the agent still serves others.
  const abrupt=await connect(socketPath);abrupt.pause();
  for(let id=0;id<40;id++)abrupt.write(JSON.stringify({kind:'mcp',line:JSON.stringify({jsonrpc:'2.0',id,method:'tools/list'})})+'\n');
  await sleep(200);abrupt.destroy();await sleep(300);
  assert.equal(agent.exitCode,null,'Agent died after client disconnected during a response');
  const next=await connect(socketPath);assert.ok((await request(next,{kind:'agentInfo'})).buildIdentifier);next.destroy();
  await waitFor(()=>unixFDs()===baselineFDs);
  console.log('Idle and in-flight disconnect cleanup passed (unlocked desktop; no protected-session lease assertion).');
} finally {
  native?.close();for(const socket of sockets)socket.destroy();
  for(const child of children){if(child.exitCode===null)child.kill('SIGTERM');}
  await sleep(300);for(const child of children){if(child.exitCode===null)child.kill('SIGKILL');}
  rmSync(root,{recursive:true,force:true});
}
