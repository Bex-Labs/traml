'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { ROOT, assertLocal } = require('./aml-compatible-db.cjs');

const directory = path.join(ROOT, '.coreaml-local', 'sanctions-refresh');
const journal = path.join(directory, 'runs.jsonl');

function execute(command, args, step, timeout) {
    const result = spawnSync(command, args, { cwd: ROOT, encoding: 'utf8', windowsHide: true, timeout });
    if (result.error) throw Error(step + ' failed (' + (result.error.code || 'process error') + ')');
    if (result.status !== 0) {
        // The fetcher and importer emit sanitized errors without request headers or credentials.
        const detail = result.stderr.trim().split(/\r?\n/).slice(0, 2).join(' ').slice(0, 320);
        throw Error(step + ' failed' + (detail ? '. ' + detail : ''));
    }
    return result.stdout;
}

function main() {
    const [python, mode, extra] = process.argv.slice(2);
    if (!python || extra || (mode && mode !== '--install')) {
        throw Error('Usage: node scripts/refresh-kyc-sanctions-local.cjs <python executable> [--install]');
    }
    assertLocal();
    fs.mkdirSync(directory, { recursive: true });
    const attempt = fs.mkdtempSync(path.join(directory, 'fetch-'));
    const snapshot = path.join(attempt, 'snapshot.json');
    try {
        execute(python, [path.join(ROOT, 'scripts/coreaml-sanctions-pilot.py'), 'refresh', snapshot],
            'Official watchlist fetch', 180000);
        const args = [path.join(ROOT, 'scripts/import-kyc-sanctions-local.cjs'), snapshot];
        if (mode !== '--install') args.push('--refresh-only');
        const imported = JSON.parse(execute(process.execPath, args, 'Local watchlist import', 120000));
        if (!['IMPORTED_LOCAL_PILOT', 'VERIFIED_UNCHANGED'].includes(imported.status)) {
            throw Error('Local importer returned an unexpected status');
        }
        if (!['SCREENED', 'ALREADY_SCREENED'].includes(imported.rescreening?.status)) {
            throw Error('Local importer did not confirm rescreening');
        }
        return imported;
    } finally {
        fs.rmSync(attempt, { recursive: true, force: true });
    }
}

const record = { started_at: new Date().toISOString() };
try {
    Object.assign(record, main());
} catch (error) {
    record.status = 'FAILED';
    record.error = String(error.message).replace(/eyJ[\w-]+\.[\w-]+\.[\w-]+/g, '[redacted]')
        .replace(/sb_secret_[\w-]+/g, '[redacted]').split(/\r?\n/)[0].slice(0, 500);
    process.exitCode = 1;
}
record.finished_at = new Date().toISOString();
try {
    fs.mkdirSync(directory, { recursive: true });
    fs.appendFileSync(journal, JSON.stringify(record) + '\n', 'utf8');
} catch {
    console.error('Unable to write the local sanctions refresh journal.');
    process.exitCode = 1;
}
console.log(JSON.stringify(record, null, 2));
