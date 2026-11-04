// Exercise the actual SDK checker on isolated LF, CRLF and modified bundles.
import fs from 'node:fs';import os from 'node:os';import path from 'node:path';import {spawnSync} from 'node:child_process';import assert from 'node:assert/strict';
const root=new URL('../',import.meta.url),tmp=fs.mkdtempSync(path.join(os.tmpdir(),'coreaml-sdk-lines-'));
try{
 fs.mkdirSync(path.join(tmp,'scripts'),{recursive:true});fs.mkdirSync(path.join(tmp,'js/vendor'),{recursive:true});
 for(const name of ['scripts/test-browser-sdk.mjs','js/config.js','js/vendor/supabase-js-2.118.0.manifest.json'])fs.copyFileSync(new URL(name,root),path.join(tmp,name));
 const original=fs.readFileSync(new URL('js/vendor/supabase-js-2.118.0.js',root),'utf8').replace(/\r\n/g,'\n');
 const file=path.join(tmp,'js/vendor/supabase-js-2.118.0.js');
 for(const [label,code,shouldPass]of [['LF',original,true],['CRLF',original.replace(/\n/g,'\r\n'),true],['Changed content',original+'\n// unexpected content edit\n',false],['Unexpected BOM','\uFEFF'+original,false]]){
  fs.writeFileSync(file,code);const result=spawnSync(process.execPath,[path.join(tmp,'scripts/test-browser-sdk.mjs')],{encoding:'utf8',timeout:15000});
  assert(!result.error,label+': '+result.error?.message);
  if(shouldPass)assert.equal(result.status,0,label+' must pass the original integrity digest and SDK functional checks: '+result.stderr);
  else{assert.notEqual(result.status,0,label+' must fail integrity verification');assert.match(result.stderr,/AssertionError/);}
 }
 console.log('PASS: actual SDK checker accepts LF and Windows CRLF with the unchanged digest, and rejects content edits and an unexpected BOM.');
}finally{fs.rmSync(tmp,{recursive:true,force:true});}
