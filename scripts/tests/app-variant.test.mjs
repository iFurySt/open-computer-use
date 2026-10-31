import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {mkdtempSync,mkdirSync,copyFileSync,writeFileSync,readFileSync,rmSync,existsSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import test from 'node:test';
const repo=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'../..');
function sandbox(t) {
  const root=mkdtempSync(path.join(tmpdir(),'ocu-variant-'));t.after(()=>rmSync(root,{recursive:true,force:true}));
  for(const file of ['scripts/build-open-computer-use-app.sh','scripts/release-package.sh','scripts/install-codex-plugin.sh','scripts/npm/build-packages.mjs']){
    const target=path.join(root,file);mkdirSync(path.dirname(target),{recursive:true});copyFileSync(path.join(repo,file),target);
  }
  const marker=path.join(root,'dist/release/keep');mkdirSync(path.dirname(marker),{recursive:true});writeFileSync(marker,'existing release');
  return {root,marker};
}
const baseEnv={...process.env,OPEN_COMPUTER_USE_APP_VARIANT:'dev',OPEN_COMPUTER_USE_INCLUDE_LOCKED_USE:'0'};
test('invalid variant and mismatched Locked Use fail before build or cleanup',t=>{
  const {root,marker}=sandbox(t);
  for(const overrides of [{OPEN_COMPUTER_USE_APP_VARIANT:'unknown'},{OPEN_COMPUTER_USE_INCLUDE_LOCKED_USE:'1'}]) {
    const r=spawnSync('bash',[path.join(root,'scripts/build-open-computer-use-app.sh'),'release'],{env:{...baseEnv,...overrides},encoding:'utf8'});
    assert.equal(r.status,1);assert.match(r.stderr,/APP_VARIANT/);assert.doesNotMatch(r.stderr,/plugin.json|swift|No such file/);
    assert.equal(readFileSync(marker,'utf8'),'existing release');
    assert.equal(existsSync(path.join(root,'dist/Open Computer Use (Dev).app')),false);
  }
});
test('packaging and plugin install reject an inherited variant before touching output',t=>{
  const {root,marker}=sandbox(t);
  for(const [command,args] of [
    ['bash',['scripts/release-package.sh']],
    ['bash',['scripts/release-package.sh','--skip-build']],
    ['bash',['scripts/install-codex-plugin.sh','--rebuild','--configuration','release']],
    [process.execPath,['scripts/npm/build-packages.mjs','--skip-build']],
    [process.execPath,['scripts/npm/build-packages.mjs']],
  ]) {
    const r=spawnSync(command,args,{cwd:root,env:baseEnv,encoding:'utf8'});
    assert.equal(r.status,1);assert.match(r.stderr,/APP_VARIANT.*unset/);
    assert.equal(readFileSync(marker,'utf8'),'existing release');
  }
});
