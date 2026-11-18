const target = document.getElementById('active-rules-body');
if (target) {
    const link = document.createElement('a');
    link.href = './dashboard.html?view=system-config&settings=rules';
    link.className = 'btn btn-sm btn-outline-primary m-3';
    link.textContent = 'Rules & detection coverage';
    link.addEventListener('click', event => {
        if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
        event.preventDefault();
        document.dispatchEvent(new Event('coreaml:open-rule-governance'));
    });
    target.closest('.card')?.prepend(link);
}
