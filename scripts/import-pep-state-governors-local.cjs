'use strict';

const { execFileSync } = require('node:child_process');
const { publicationSql } = require('./import-pep-senate-local.cjs');

const url = 'https://www.ngf.org.ng/index.php/the-ngf/governors';
const source = 'Nigeria Governors’ Forum national directory';
const states = new Set([
    'Abia', 'Adamawa', 'Akwa Ibom', 'Anambra', 'Bauchi', 'Bayelsa', 'Benue',
    'Borno', 'Cross River', 'Delta', 'Ebonyi', 'Edo', 'Ekiti', 'Enugu', 'Gombe',
    'Imo', 'Jigawa', 'Kaduna', 'Kano', 'Katsina', 'Kebbi', 'Kogi', 'Kwara',
    'Lagos', 'Nasarawa', 'Niger', 'Ogun', 'Ondo', 'Osun', 'Oyo', 'Plateau',
    'Rivers', 'Sokoto', 'Taraba', 'Yobe', 'Zamfara'
]);

function parseRoster(html) {
    const pattern = /<h3 itemprop="name">\s*<a href="(\/index\.php\/the-ngf\/governors\/\d+-[a-z-]+-state-governor)"[^>]*>\s*([^<]+)<\/a>\s*<\/h3>((?:(?!<h3\b)[\s\S])*?)<div class="magazine-item-ct">([\s\S]*?)<\/div>/g;
    const cards = [...html.matchAll(pattern)];
    if (cards.length !== states.size) throw Error('Expected one profile for each of the 36 states.');

    const seenStates = new Set();
    const seenProfiles = new Set();
    return cards.map(([, profile, heading, , body]) => {
        const state = heading.trim().match(/^(.+) State Governor$/)?.[1].replace(/-/g, ' ');
        const names = [...body.matchAll(/<p\b[^>]*>([\s\S]*?)<\/p>/gi)]
            .map(([, value]) => value.replace(/&nbsp;|&#160;/g, ' ').replace(/<\/?(?:span|strong|em)\b[^>]*>/gi, '').trim())
            .filter(Boolean);
        if (!states.has(state) || seenStates.has(state) || seenProfiles.has(profile) || names.length !== 1) {
            throw Error('Unexpected or duplicate state, name or governor profile.');
        }
        const name = names[0].normalize('NFC').replace(/\s+/gu, ' ')
            .replace(/^(?:(?:Rt\.|Hon\.|Dr\.|Sen\.|Engr\.|Prof\.|Rev\.|Fr\.|Pastor|Engineer|Alhaji|Prince)\s+)+/i, '')
            .replace(/\s+(?:CFR|CON|OFR|MFR|MON)$/i, '');
        if (name.length < 2 || name.length > 200 || /[<>&\x00-\x1f\x7f]/.test(name)) {
            throw Error('Invalid governor name.');
        }
        seenStates.add(state);
        seenProfiles.add(profile);
        return {
            source_reference: new URL(profile, url).href,
            full_name: name,
            public_role: `Governor · ${state} State`,
            jurisdiction: 'Nigeria'
        };
    });
}

function main() {
    const [mode, extra] = process.argv.slice(2);
    if (extra || !['--preview', '--apply-local'].includes(mode)) {
        throw Error('Usage: node scripts/import-pep-state-governors-local.cjs --preview | --apply-local');
    }
    const local = mode === '--apply-local' ? require('./aml-compatible-db.cjs') : null;
    if (local) local.assertLocal();
    const html = execFileSync('curl', [
        '--silent', '--show-error', '--fail', '--proto', '=https', '--max-time', '25', url
    ], { encoding: 'utf8', timeout: 30000, maxBuffer: 1024 * 1024, windowsHide: true });
    const rows = parseRoster(html);
    if (local && Number(local.query(publicationSql(rows, local.lit, source))) !== rows.length) {
        throw Error('Local governors import count could not be confirmed.');
    }
    console.log(JSON.stringify({
        status: local ? 'IMPORTED_LOCAL' : 'PREVIEW',
        source, records: rows.length, coverage: '36 state offices represented; incumbent names as published by the directory', roster: url,
        ...(mode === '--preview' ? { candidates: rows } : {})
    }, null, 2));
}

if (require.main === module) {
    try { main(); }
    catch (error) {
        console.error('State governors import stopped:', error.stderr?.toString().trim() || error.message);
        process.exitCode = 1;
    }
}
module.exports = { parseRoster };
