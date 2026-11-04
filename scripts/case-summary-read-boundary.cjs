'use strict';
const uuid=v=>typeof v==='string'&&/^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i.test(v);
function summaryReadAllowed(method,body,fixture){if(method==='OPTIONS')return true;return method==='POST'&&body&&Object.keys(body).length===1&&uuid(body.p_alert_id)&&[fixture.qa,fixture.qaMember,fixture.executive,fixture.execMember].includes(body.p_alert_id);}
module.exports={summaryReadAllowed};
