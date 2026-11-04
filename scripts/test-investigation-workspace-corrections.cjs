const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict'),vm=require('node:vm');
const root=path.resolve(__dirname,'..'),read=p=>fs.readFileSync(path.join(root,p),'utf8');
const html=read('dashboard.html'),start=html.indexOf('const requestedReturn ='),end=html.indexOf(';',html.indexOf('const savedView =',start));
assert(start>=0&&end>start);
function restore(storedView,query=''){return vm.runInNewContext(html.slice(start,end+1)+';savedView',{URL,window:{location:{href:'http://localhost/dashboard.html'+query}},storedView});}
assert.equal(restore('investigation-workspace'),'case-management');assert.equal(restore('investigation-workspace','?view=case-management'),'case-management');assert.equal(restore('case-management','?view=command-center'),'command-center');assert.equal(restore('intelligence'),'command-center');assert.equal(restore('case-management','?view=unknown'),'case-management');console.log('PASS Actual restore expression routes unloaded investigations safely and accepts only supported return targets');
const summary=read('case-summary.html');assert(summary.includes('href="./dashboard.html?view=case-management"'));console.log('PASS Internal summary returns explicitly to Case Management');
const js=read('js/controllers/investigation-layout.js'),css=read('css/investigation-layout.css');
assert(js.includes("snapshot.classList.remove('h-100')"));assert(js.indexOf('root.append(snapshot)')<js.indexOf('root.append(evidenceCard,graphDetails,historyDetails)'));assert(js.indexOf('root.append(subjects)')<js.indexOf('root.append(narrativeCard)'));assert(js.indexOf('root.append(narrativeCard)')<js.indexOf('root.append(footer)'));assert(css.includes('.iw-actions .iw-close-action{margin-left:0!important}'));console.log('PASS Layout source stacks independent sections, puts findings last and removes the automatic close-button spacer');
console.log('3 regression checks passed; signed-in visual verification remains required.');
