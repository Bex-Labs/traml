'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { createHash } = require('node:crypto');
const { assertLocal, query, lit, ROOT } = require('./aml-compatible-db.cjs');

const expectedFiles = {
    un: 'https://scsanctions.un.org/resources/xml/en/consolidated.xml',
    sdn: 'https://www.treasury.gov/ofac/downloads/sdn.csv',
    sdn_alias: 'https://www.treasury.gov/ofac/downloads/alt.csv',
    non_sdn: 'https://www.treasury.gov/ofac/downloads/consolidated/cons_prim.csv',
    non_sdn_alias: 'https://www.treasury.gov/ofac/downloads/consolidated/cons_alt.csv',
    nigeria: 'https://nigsac.gov.ng/IndSancList',
};
const sources = ['UN', 'OFAC_SDN', 'OFAC_NON_SDN', 'NIGERIA'];
const kinds = ['individual', 'entity', 'vessel', 'aircraft'];
const bounded = (value, max) => typeof value === 'string' && value.trim().length > 0 && value.length <= max;

try {
    const [snapshotFile, mode, extra] = process.argv.slice(2);
    if (!snapshotFile || extra || (mode && mode !== '--refresh-only')) {
        throw Error('Usage: node scripts/import-kyc-sanctions-local.cjs <snapshot.json> [--refresh-only]');
    }
    const file = path.resolve(snapshotFile);
    assertLocal();
    if (fs.statSync(file).size > 32 * 1024 * 1024) throw Error('Snapshot exceeds 32 MiB');
    const raw = fs.readFileSync(file);
    const { version, retrieved_at, files, entries } = JSON.parse(raw.toString('utf8'));
    const timestamp = Date.parse(retrieved_at);
    if (version !== 1 || !Number.isFinite(timestamp) || timestamp > Date.now() + 60000 ||
        timestamp < Date.now() - 7 * 86400000 || !Array.isArray(entries) || entries.length > 100000) {
        throw Error('Refresh the version 1 pilot snapshot before importing');
    }

    for (const [key, url] of Object.entries(expectedFiles)) {
        if (files?.[key]?.url !== url || !/^[0-9a-f]{64}$/.test(files[key].sha256)) {
            throw Error('Snapshot source metadata is incomplete');
        }
    }

    const seen = new Set();
    const counts = Object.fromEntries(sources.map(source => [source, 0]));
    for (const entry of entries) {
        if (!entry || !sources.includes(entry.source) || !kinds.includes(entry.kind) ||
            !bounded(entry.name, 1000) || !bounded(entry.reference, 150) ||
            !Array.isArray(entry.aliases) || entry.aliases.length > 1000 ||
            entry.aliases.some(alias => !bounded(alias, 1000))) {
            throw Error('Invalid snapshot entry');
        }
        const key = JSON.stringify([entry.source, entry.reference]);
        if (seen.has(key)) throw Error('Duplicate source reference');
        seen.add(key);
        counts[entry.source]++;
    }
    if (Object.values(counts).some(count => count === 0)) throw Error('Snapshot is missing a source');

    const sha = createHash('sha256').update(raw).digest('hex');
    const sql = mode === '--refresh-only' ? '' : [
        'coreaml-kyc-sanctions-local.sql',
        'coreaml-kyc-sanctions-rescreen-local.sql',
    ].map(name => fs.readFileSync(path.join(ROOT, 'sql', name), 'utf8')).join('\n');
    const result = JSON.parse(query(`BEGIN;
        SET LOCAL standard_conforming_strings = on;
        ${sql}
        WITH imported AS MATERIALIZED (
            SELECT coreaml_private.import_kyc_sanctions_snapshot(
                ${lit(sha)}, ${lit(new Date(timestamp).toISOString())},
                ${lit(JSON.stringify(entries))}::jsonb, ${lit(JSON.stringify(files))}::jsonb
            ) AS receipt
        )
        SELECT receipt || jsonb_build_object(
            'rescreening', coreaml_private.rescreen_kyc_sanctions_snapshot(receipt->>'sha256')
        ) FROM imported;
        COMMIT;`));
    console.log(JSON.stringify({ ...result, downloaded_sha256: sha, retrieved_at, counts }, null, 2));
} catch (error) {
    console.error('Sanctions pilot import stopped:', String(error.message).split('\n')[0]);
    process.exitCode = 1;
}
