'use strict';
const {ids,same}=require('./review-acceptance-tools.cjs');
function timelineReadAllowed(method,body,fixture){if(method==='OPTIONS')return true;return method==='POST'&&body&&same(Object.keys(body).sort(),['p_alert_id','p_before','p_before_key','p_limit'])&&ids(fixture).includes(body.p_alert_id)&&Number.isInteger(body.p_limit)&&body.p_limit>=1&&body.p_limit<=50&&((body.p_before===null&&body.p_before_key===null)||(typeof body.p_before==='string'&&Number.isFinite(Date.parse(body.p_before))&&/^(claim|action|submission|review):[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/.test(body.p_before_key)));}
module.exports={timelineReadAllowed};
