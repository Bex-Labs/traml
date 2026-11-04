'use strict';const {worklistReadAllowed}=require('./case-worklists-read-boundary.cjs');
function ageingReadAllowed(method,b){if(method==='OPTIONS')return true;if(!b)return false;const {p_sort,p_severity,p_min_hours,p_waiting_only,...base}=b;return worklistReadAllowed(method,base)&&['NEWEST','OLDEST','SEVERITY'].includes(p_sort)&&['ALL','CRITICAL','HIGH','MEDIUM','LOW','UNRECORDED'].includes(p_severity)&&Number.isInteger(p_min_hours)&&p_min_hours>=0&&p_min_hours<=87600&&typeof p_waiting_only==='boolean';}
module.exports={ageingReadAllowed};
