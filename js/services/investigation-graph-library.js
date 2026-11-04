// Optional visualization: never start this request during dashboard startup.
const SOURCE = 'https://unpkg.com/vis-network/standalone/umd/vis-network.min.js';
let pending;

export function loadInvestigationGraphLibrary() {
    if (window.vis?.DataSet && window.vis?.Network) return Promise.resolve(window.vis);
    if (pending) return pending;
    pending = new Promise((resolve, reject) => {
        const script = document.createElement('script');
        script.async = true;
        script.src = SOURCE;
        const finish = (error) => {
            clearTimeout(deadline);
            script.onload = script.onerror = null;
            if (error) {
                script.remove();
                reject(error);
            } else resolve(window.vis);
        };
        const deadline = setTimeout(() => finish(new Error('Graph library timed out.')), 10000);
        script.onload = () => finish(window.vis?.DataSet && window.vis?.Network
            ? null : new Error('Graph library is unavailable.'));
        script.onerror = () => finish(new Error('Graph library could not be loaded.'));
        document.head.appendChild(script);
    }).catch(error => {
        pending = undefined;
        throw error;
    });
    return pending;
}
