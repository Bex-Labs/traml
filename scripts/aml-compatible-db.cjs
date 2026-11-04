'use strict';
const fs=require('node:fs'),path=require('node:path'),{spawnSync}=require('node:child_process');
const ROOT=path.resolve(__dirname,'..'),DB='supabase_db_sentinel-aml',API='http://127.0.0.1:55321',BANK='a1000000-0000-4000-8000-000000000001';
function run(command,args,input){const p=spawnSync(command,args,{input,encoding:'utf8',timeout:90000,maxBuffer:8*1024*1024});if(p.error||p.status!==0)throw Error(p.error?.message||p.stderr||command+' failed');return p.stdout;}
function query(sql){return run('docker',['exec','-i',DB,'psql','-X','-q','-v','ON_ERROR_STOP=1','-U','postgres','-d','postgres','-At'],"SET statement_timeout='60s';SET lock_timeout='5s';\n"+sql).trim();}
function assertLocal(){process.chdir(ROOT);if(!/^project_id\s*=\s*"sentinel-aml"/m.test(fs.readFileSync('supabase/config.toml','utf8')))throw Error('Wrong local project');const d=JSON.parse(run('docker',['inspect',DB]))[0];if(!d.State?.Running||!d.NetworkSettings?.Ports?.['5432/tcp']?.some(p=>p.HostPort==='55322'))throw Error('Expected local Docker database on port 55322');}
const lit=x=>"'"+String(x).replace(/'/g,"''")+"'";
module.exports={ROOT,DB,API,BANK,run,query,assertLocal,lit};
