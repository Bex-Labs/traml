// A full page for substantial configuration; leave investigation navigation guards intact.
const target=document.getElementById('active-rules-body');
if(target){const link=document.createElement('a');link.href='./rule-governance.html';link.className='btn btn-sm btn-outline-primary m-3';link.textContent='Rules & detection coverage';target.closest('.card')?.prepend(link);}
