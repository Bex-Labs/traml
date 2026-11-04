const UUID=/^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i;
const ORIGINS=new Set(['http://127.0.0.1:5520','http://localhost:5520']);
const EXAMPLES=Object.freeze({nin:'12345678901',bvn:'12345678901',phone:'08012345678'});
export function createHandler({env,fetcher=fetch,timeout=20000,now=()=>Date.now()}){
 const limits=new Map();
 return async req=>{
  const origin=req.headers.get('origin');const headers={'Content-Type':'application/json','Cache-Control':'no-store','Vary':'Origin'};
  if(origin&&ORIGINS.has(origin))Object.assign(headers,{'Access-Control-Allow-Origin':origin,'Access-Control-Allow-Headers':'authorization, apikey, content-type, x-client-info, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version','Access-Control-Allow-Methods':'POST, OPTIONS'});
  const reply=(status,data)=>new Response(JSON.stringify(data),{status,headers});
  if(origin&&!ORIGINS.has(origin))return reply(403,{error:'Origin not allowed'});
  if(req.method==='OPTIONS')return new Response(null,{status:204,headers});
  if(req.method!=='POST')return reply(405,{error:'POST required'});
  const authorization=req.headers.get('authorization')||'';if(!/^Bearer \S+$/i.test(authorization))return reply(401,{error:'Sign in to CoreAML first'});
  const controller=new AbortController(),timer=setTimeout(()=>controller.abort(),timeout);let slot,acquired=false;
  try{
   const url=env('SUPABASE_URL')?.replace(/\/$/,''),anon=env('SUPABASE_ANON_KEY');
   if(!url||!anon)return reply(503,{error:'Local Supabase environment is unavailable'});
   const dbHeaders={apikey:anon,Authorization:authorization};
   const read=async route=>{const r=await fetcher(url+route,{headers:dbHeaders,signal:controller.signal,redirect:'error'});if(!r.ok)throw {status:r.status===401?401:503,message:r.status===401?'Session expired. Sign in again.':'Authorized record lookup unavailable'};return r.json();};
   const user=await read('/auth/v1/user');if(!UUID.test(user?.id||''))return reply(401,{error:'Session was not confirmed'});
   const profiles=await read('/rest/v1/user_profiles?select=id,role,tenant_id,is_active&id=eq.'+user.id+'&limit=1');
   const p=profiles?.[0];if(!Array.isArray(profiles)||profiles.length!==1||p.id!==user.id||p.is_active!==true||!UUID.test(p.tenant_id||'')||!['compliance_officer','head_of_compliance'].includes(p.role)||user.app_metadata?.role!==p.role||user.app_metadata?.tenant_id!==p.tenant_id)return reply(403,{error:'Active authorized bank profile required'});
   if(!req.headers.get('content-type')?.toLowerCase().startsWith('application/json'))return reply(415,{error:'JSON body required'});
   if(Number(req.headers.get('content-length')||0)>2048)return reply(413,{error:'Request too large'});
   let input;const reader=req.body?.getReader();if(!reader)return reply(400,{error:'Request body required'});let chunks=[],size=0;const stopRead=()=>{void reader.cancel().catch(()=>{});};controller.signal.addEventListener('abort',stopRead,{once:true});try{while(true){const r=await reader.read();if(controller.signal.aborted)throw Error('timeout');if(r.done)break;size+=r.value.length;if(size>2048){await reader.cancel();return reply(413,{error:'Request too large'});}chunks.push(r.value);}}finally{controller.signal.removeEventListener('abort',stopRead);}const body=new Uint8Array(size);let off=0;for(const c of chunks){body.set(c,off);off+=c.length;}try{input=JSON.parse(new TextDecoder().decode(body));}catch{return reply(400,{error:'Invalid JSON'});}
   if(!input||Array.isArray(input)||Object.keys(input).sort().join(',')!=='customer_id,type'||!UUID.test(input.customer_id||'')||!Object.hasOwn(EXAMPLES,input.type))return reply(400,{error:'Only customer_id and type (nin, bvn or phone) are accepted'});
   const customers=await read('/rest/v1/customers?select=id,tenant_id&id=eq.'+input.customer_id+'&tenant_id=eq.'+p.tenant_id+'&limit=1');
   if(!Array.isArray(customers)||customers.length!==1||customers[0]?.id!==input.customer_id||customers[0]?.tenant_id!==p.tenant_id)return reply(403,{error:'Customer unavailable in your bank'});
   const apiKey=env('PROVN_API_KEY')?.trim(),accessKey=env('PROVN_ACCESS_KEY')?.trim();
   if(env('PROVN_MODE')!=='test'||!apiKey?.startsWith('test_')||apiKey.includes('REPLACE')||!/^[A-Za-z0-9_-]{16,128}$/.test(accessKey||''))return reply(503,{error:'PROVN configuration checks: '+JSON.stringify({mode_is_test:env('PROVN_MODE')==='test',api_key_present:!!apiKey,api_key_has_test_prefix:!!apiKey?.startsWith('test_'),api_key_has_placeholder:!!apiKey?.includes('REPLACE'),access_key_present:!!accessKey,access_key_is_uuid:UUID.test(accessKey||'')})});
   // Local worker safeguard only; production needs shared rate limiting.
   const timestamp=now();for(const [k,v] of limits)if(!v.busy&&timestamp-v.start>=60000)limits.delete(k);
   slot=limits.get(user.id);if(slot?.busy||slot&&slot.count>=5&&timestamp-slot.start<60000)return reply(429,{error:'Wait before another PROVN sandbox request'});
   if(!slot||timestamp-slot.start>=60000)slot={start:timestamp,count:0,busy:false};slot.count++;slot.busy=true;acquired=true;limits.set(user.id,slot);
   const requestId=crypto.randomUUID();
   const upstream=await fetcher('https://api.provn.ng/verification/'+input.type,{method:'POST',headers:{'Content-Type':'application/json','API-Key':apiKey,'Access-Key':accessKey},body:JSON.stringify({[input.type]:EXAMPLES[input.type]}),signal:controller.signal,redirect:'error'});
   if(!upstream.ok){const detail=[401,403].includes(upstream.status)?'PROVN rejected the test credentials or organization configuration.':upstream.status===429?'PROVN rate limit reached. Wait before retrying.':'PROVN test service returned an error.';return reply(upstream.status===429?429:502,{error:detail,provider_http_status:upstream.status,request_id:requestId});}
   let result;try{result=await upstream.json();}catch{return reply(502,{error:'PROVN returned unreadable test data',request_id:requestId});}
   const data=result?.data,short=v=>typeof v==='string'&&v.trim().length>0&&v.length<=200;
   if(result?.status!=='success'||result?.code!==200||!data||typeof data!=='object'||Array.isArray(data)||(input.type==='phone'?typeof data.is_valid!=='boolean'||!short(data.network):!short(data.first_name)||!short(data.last_name)))return reply(502,{error:'PROVN did not return the documented test response',request_id:requestId});
   const demo=input.type==='phone'?{is_valid:data.is_valid,network:data.network}:{first_name:data.first_name,last_name:data.last_name};
   return reply(200,{provider:'PROVN',mode:'TEST',state:'SANDBOX_RESPONSE_RECEIVED',verification_type:input.type,customer_id:input.customer_id,customer_identity_verified:false,customer_updated:false,request_id:requestId,checked_at:new Date(now()).toISOString(),dummy_data:demo,notice:'Provider-hosted test response using documentation example input. Not proof of this customer identity, address or sanctions clearance. No account was activated.'});
  }catch(e){return reply(controller.signal.aborted?504:(e?.status||502),{error:controller.signal.aborted?'PROVN sandbox request timed out. No customer approval was recorded.':e?.message&&e?.status?e.message:'PROVN sandbox connection failed. No customer approval was recorded.'});}
  finally{clearTimeout(timer);if(acquired)slot.busy=false;}
 };
}
