#!/usr/bin/env node
// Exercise the real CLI -> app-agent path with an isolated socket namespace.
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {mkdtempSync,mkdirSync,writeFileSync,rmSync,existsSync} from 'node:fs';
import {createConnection} from 'node:net';
import {tmpdir} from 'node:os';
import path from 'node:path';
const binary=path.resolve(process.argv[2]);
const root=mkdtempSync(path.join(tmpdir(),'ocu-cli-path-'));
const cwd=path.join(root,'caller 中文');mkdirSync(cwd);
const namespace=`cli-path-${process.pid}-${Date.now()}`;
const socketPath=path.join(tmpdir(),`open-computer-use-agent-${createHash('sha256').update(namespace).digest('hex').slice(0,16)}.sock`);
const env={...process.env,OPEN_COMPUTER_USE_DISABLE_APP_AGENT_PROXY:'0',
  OPEN_COMPUTER_USE_AGENT_SOCKET_NAMESPACE:namespace,OPEN_COMPUTER_USE_VISUAL_CURSOR:'0',
  OPEN_COMPUTER_USE_CONFIG_FILE:path.join(root,'config.json')};
writeFileSync(path.join(cwd,'calls 中文.json'),JSON.stringify([{tool:'list_apps'}]));
writeFileSync(path.join(cwd,'args 中文.json'),'{}');
function run(args,expected=0) {
  const r=spawnSync(binary,args,{cwd,env,encoding:'utf8',timeout:30000});
  assert.equal(r.status,expected,`${args.join(' ')}\n${r.stderr}\n${r.stdout}`);
  return r;
}
try {
  run(['call','--calls-file','./calls 中文.json','--sleep','0']);
  assert.ok(existsSync(socketPath),'Test did not use the app-agent socket');
  run(['call','list_apps','--args-file','args 中文.json']);
  run(['call','--calls-file',path.join(cwd,'calls 中文.json')]);
  run(['call','list_apps','--args-file','../caller 中文/args 中文.json']);
  const missing=run(['call','list_apps','--args-file','missing.json'],1);
  assert.ok(missing.stderr.includes(path.join(cwd,'missing.json')),missing.stderr);
  // Resolving paths must not change the caller's or agent's global cwd.
  run(['call','list_apps','--args-file','args 中文.json']);
  console.log('Real app-agent CLI: relative, absolute, parent, Unicode/space paths and missing-file diagnostics passed.');
} finally {
  if(existsSync(socketPath)) await new Promise(resolve=>{
    const socket=createConnection(socketPath);const timer=setTimeout(()=>{socket.destroy();resolve();},3000);
    socket.on('error',()=>{clearTimeout(timer);resolve();});
    socket.on('connect',()=>socket.end(JSON.stringify({kind:'terminate'})+'\n'));
    socket.on('close',()=>{clearTimeout(timer);resolve();});
  });
  rmSync(root,{recursive:true,force:true});
}
