'use strict';
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict'),Module=require('node:module');
const file=path.join(__dirname,'case-workflow-acceptance-tools.cjs'),m=new Module(file,module);m.filename=file;m.paths=module.paths;
m.require=name=>name.startsWith('./')?{}:require(name);m._compile(fs.readFileSync(file,'utf8'),file);
(async()=>{
 const calls=[];let release;const dom=new Promise(resolve=>release=resolve);
 const page={waitForLoadState:(state,options)=>{calls.push({state,options});return dom;},locator:selector=>({waitFor:async options=>calls.push({selector,options})})};
 const work=m.exports.awaitLoginForm(page);assert.deepEqual(calls,[{state:'domcontentloaded',options:{timeout:60000}}]);release();await work;
 assert.deepEqual(calls.slice(1).map(c=>c.selector),['#login-form','#email','#password','#login-form button[type=submit]']);assert(calls.slice(1).every(c=>c.options.state==='visible'&&c.options.timeout===10000));
 console.log('PASS Actual document readiness precedes bounded visible-form checks');
 let located=false;await assert.rejects(()=>m.exports.awaitLoginForm({waitForLoadState:async()=>{throw Error('Document deadline');},locator:()=>{located=true;}}),/Document deadline/);assert.equal(located,false);
 console.log('PASS Document timeout fails without attempting form interaction or forced login');
 const source=fs.readFileSync(path.join(__dirname,'verify-case-workflow-acceptance-local.cjs'),'utf8');assert(source.indexOf("phaseA('login_document_and_form_ready'")<source.indexOf("a.locator('#email').fill"));
 console.log('PASS Actual acceptance harness waits before filling credentials');
 console.log('3 login-readiness checks passed; rerun the existing native acceptance next.');
})().catch(e=>{console.error(e.stack);process.exitCode=1;});
