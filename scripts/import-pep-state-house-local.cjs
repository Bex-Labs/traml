'use strict';

const path = require('node:path');
const { execFileSync } = require('node:child_process');
const { publicationSql } = require('./import-pep-senate-local.cjs');

const source = 'Nigeria State House federal executive roster';

function fetchPage(page) {
    return execFileSync('curl', [
        '--silent', '--show-error', '--fail', '--proto', '=https',
        '--max-time', '30', `https://statehouse.gov.ng/${page}/`
    ], { timeout: 35000, maxBuffer: 1024 * 1024, windowsHide: true, encoding: 'utf8' });
}

try {
    const [mode, python = 'python', extra] = process.argv.slice(2);
    if (extra || !['--preview', '--apply-local'].includes(mode)) {
        throw Error('Usage: node scripts/import-pep-state-house-local.cjs --preview | --apply-local [python executable]');
    }
    const local = mode === '--apply-local' ? require('./aml-compatible-db.cjs') : null;
    if (local) local.assertLocal();
    const pages = {cabinet: fetchPage('the-cabinet'), leadership: fetchPage('people')};
    const {rows, ...coverage} = JSON.parse(execFileSync(python, [path.join(__dirname, 'parse-pep-state-house.py')], {
        input: JSON.stringify(pages), encoding: 'utf8', timeout: 10000, windowsHide: true
    }));
    if (local && Number(local.query(publicationSql(rows, local.lit, source))) !== rows.length) {
        throw Error('Local State House import count could not be confirmed.');
    }
    console.log(JSON.stringify({
        status: local ? 'IMPORTED_LOCAL' : 'PREVIEW', source,
        records: rows.length, leadership_profiles: 2, ...coverage,
        coverage: 'Named entries on the State House pages only.'
    }, null, 2));
} catch (error) {
    console.error('State House import stopped:', error.stderr?.toString().trim() || error.message);
    process.exitCode = 1;
}
