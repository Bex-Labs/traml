export const escapeText=x=>String(x??'Not recorded').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
export const time=x=>x&&Number.isFinite(Date.parse(x))?new Intl.DateTimeFormat('en-GB',{dateStyle:'medium',timeStyle:'short',timeZone:'Africa/Lagos'}).format(new Date(x))+' WAT':'Not recorded';
export function money(amount,currency){const match=String(amount??'').match(/^(-?)(\d+)(?:\.(\d+))?$/);return match?(currency||'Currency unavailable')+' '+match[1]+match[2].replace(/\B(?=(\d{3})+(?!\d))/g,',')+'.'+(match[3]||'').padEnd(2,'0'):'Amount unavailable';}
export function table(headers,rows){return '<div class="table-wrap"><table><thead><tr>'+headers.map(h=>'<th scope="col">'+escapeText(h)+'</th>').join('')+'</tr></thead><tbody>'+(rows.length?rows.join(''):`<tr><td colspan="${headers.length}">No records match this view.</td></tr>` )+'</tbody></table></div>';}
export function facts(entries){return '<dl class="facts">'+entries.map(([k,v])=>`<div><dt>${escapeText(k)}</dt><dd>${escapeText(v)}</dd></div>`).join('')+'</dl>';}
export function roleMatrix(){return table(['Role','Authorized responsibilities','Excluded responsibilities'],[
 ['Bank oversight manager','Read-only oversight of the assigned bank, case progress and measured reporting totals','Investigating, approving reports, filing, changing customer or bank balances'],
 ['Compliance officer','Assigned investigations, structured dismissal requests and report preparation','Self-approval, platform administration and other banks'],
 ['Head of Compliance','Independent compliance decisions; assigned-bank officer invitations and access management','Other banks, platform administrator provisioning and self-management'],
 ['Platform administrator','Institutions, supported staff provisioning, access suspension/restoration and administrative audit','Customer evidence, banking transaction injection and regulatory approval'],
 ['Branch manager / legacy banking manager','Existing bank operational workflow under its separate authorization','Compliance approval and platform administration'],
 ['Teller / sales representative','Existing assigned-bank operational and onboarding workflow','Compliance approval and platform administration']
 ].map(r=>'<tr>'+r.map(c=>`<td>${escapeText(c)}</td>`).join('')+'</tr>'));}
