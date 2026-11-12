'use strict';

const { createHash } = require('node:crypto');
const { execFileSync } = require('node:child_process');

const roster = 'https://www.nass.gov.ng/mps/senators';
const feed = 'https://www.nass.gov.ng/mps/get_legislators/?chamber=1&draw=1&start=0&length=109';
const source = 'Nigeria National Assembly Senate roster';
const maxSeats = 109;

function clean(value, limit) {
    if (typeof value !== 'string' || /[<>\x00-\x1f\x7f]/.test(value)) {
        throw Error('Unexpected text in the Senate roster.');
    }
    const normalized = value.normalize('NFC').trim().replace(/\s+/gu, ' ');
    if (!normalized || normalized.length > limit) throw Error('Invalid Senate roster field length.');
    return normalized;
}

function parseRoster(payload) {
    const { draw, recordsTotal, recordsFiltered, data } = JSON.parse(payload);
    if (draw !== 1 || !Number.isInteger(recordsTotal) || recordsTotal < 1 || recordsTotal > maxSeats ||
        recordsFiltered !== recordsTotal || !Array.isArray(data) || data.length !== recordsTotal) {
        throw Error('The endpoint returned a partial or unexpected Senate roster.');
    }

    const references = new Set();
    return data.map(row => {
        if (!Array.isArray(row) || row.length !== 5 || typeof row[4] !== 'string' ||
            !/^[1-9]\d{0,11}$/.test(row[4]) || references.has(row[4])) {
            throw Error('Invalid or duplicate National Assembly profile reference.');
        }
        references.add(row[4]);
        const name = clean(row[0], 200);
        const state = clean(row[1], 100);
        const district = clean(row[2], 100);
        return {
            source_reference: `https://www.nass.gov.ng/mps/single/${row[4]}`,
            full_name: name,
            public_role: clean(`Senator · ${district} (${state})`, 200),
            jurisdiction: 'Nigeria',
        };
    });
}

function publicationSql(rows, lit) {
    return `BEGIN;
SET LOCAL standard_conforming_strings = on;
LOCK TABLE coreaml_private.pep_officeholder_records IN SHARE ROW EXCLUSIVE MODE;
CREATE TEMP TABLE senate_roster_import ON COMMIT DROP AS
SELECT * FROM jsonb_to_recordset(${lit(JSON.stringify(rows))}::jsonb)
AS r(source_reference text, full_name text, public_role text, jurisdiction text);
DO $$
DECLARE previous_count integer; incoming_count integer;
BEGIN
    SELECT count(*) INTO previous_count
    FROM coreaml_private.pep_officeholder_records WHERE source_name=${lit(source)};
    SELECT count(*) INTO incoming_count FROM pg_temp.senate_roster_import;
    IF previous_count > 0 AND incoming_count * 10 < previous_count * 9 THEN
        RAISE EXCEPTION 'Senate roster shrank by more than 10 percent. Inspect the source before publishing.';
    END IF;
    IF EXISTS (
        SELECT 1 FROM pg_temp.senate_roster_import i
        JOIN coreaml_private.pep_officeholder_records r USING (source_reference)
        WHERE r.source_name <> ${lit(source)}
    ) THEN
        RAISE EXCEPTION 'A Senate profile reference belongs to another source.';
    END IF;
END
$$;
DELETE FROM coreaml_private.pep_officeholder_records r
WHERE r.source_name=${lit(source)}
  AND NOT EXISTS (SELECT 1 FROM pg_temp.senate_roster_import i WHERE i.source_reference=r.source_reference);
INSERT INTO coreaml_private.pep_officeholder_records
    (source_reference,full_name,public_role,jurisdiction,source_name,checked_at,valid_until)
SELECT source_reference,full_name,public_role,jurisdiction,${lit(source)},now(),now()+interval '7 days'
FROM pg_temp.senate_roster_import
ON CONFLICT (source_reference) DO UPDATE SET
    full_name=excluded.full_name, public_role=excluded.public_role,
    jurisdiction=excluded.jurisdiction, checked_at=excluded.checked_at, valid_until=excluded.valid_until;
SELECT count(*) FROM coreaml_private.pep_officeholder_records WHERE source_name=${lit(source)};
COMMIT;`;
}

function main() {
    const [mode, extra] = process.argv.slice(2);
    if (extra || !['--preview', '--apply-local'].includes(mode)) {
        throw Error('Usage: node scripts/import-pep-senate-local.cjs --preview | --apply-local');
    }

    const local = mode === '--apply-local' ? require('./aml-compatible-db.cjs') : null;
    if (local) local.assertLocal();
    const payload = execFileSync('curl', [
        '--silent', '--show-error', '--fail', '--proto', '=https', '--max-time', '30', feed,
    ], { timeout: 35000, maxBuffer: 512 * 1024, windowsHide: true, encoding: 'utf8' });
    const rows = parseRoster(payload);
    if (local && Number(local.query(publicationSql(rows, local.lit))) !== rows.length) {
        throw Error('The local import count could not be confirmed.');
    }
    console.log(JSON.stringify({
        status: local ? 'IMPORTED_LOCAL' : 'PREVIEW',
        source, roster, retrieved_at: new Date().toISOString(),
        source_sha256: createHash('sha256').update(payload).digest('hex'),
        roster_records: rows.length, senate_seats: maxSeats,
        coverage: 'People listed by this source. No match is limited to the imported roster.',
        ...(local ? { valid_for_days: 7 } : {})
    }, null, 2));
}

if (require.main === module) {
    try {
        main();
    } catch (error) {
        console.error('Senate roster import stopped:', error.stderr?.toString().trim() || error.message);
        process.exitCode = 1;
    }
}
module.exports = { parseRoster, publicationSql };
