import {supabase} from '../config.js';
import {getVerifiedSession} from '../services/auth.service.js';
import {createCaseSummaryService} from '../services/case-summary.service.js';
import {createCaseSummaryPage} from './case-summary.controller.js';
const id=new URL(location.href).searchParams.get('alert');
const page=createCaseSummaryPage({root:document.getElementById('summary-document'),status:document.getElementById('summary-status'),refresh:document.getElementById('summary-refresh'),print:document.getElementById('summary-print'),service:createCaseSummaryService(supabase,getVerifiedSession),id});
void page.load();
