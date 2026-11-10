import { Parser } from 'npm:htmlparser2@10.0.0';
import Papa from 'npm:papaparse@5.7.0';
import { SaxesParser } from 'npm:saxes@6.0.0';

const treasury = 'https://www.treasury.gov/ofac/downloads/';
const urls = {
    un: 'https://scsanctions.un.org/resources/xml/en/consolidated.xml',
    sdn: treasury + 'sdn.csv',
    sdn_alias: treasury + 'alt.csv',
    non_sdn: treasury + 'consolidated/cons_prim.csv',
    non_sdn_alias: treasury + 'consolidated/cons_alt.csv',
    nigeria: 'https://nigsac.gov.ng/IndSancList',
};
const hosts = new Set([
    'scsanctions.un.org', 'unsolprodfiles.blob.core.windows.net',
    'www.treasury.gov', 'ofac.treasury.gov', 'sanctionslistservice.ofac.treas.gov',
    'wc2h-sls-prod-public-published.s3.us-gov-west-1.amazonaws.com', 'nigsac.gov.ng',
]);
const feedLimit = 8 * 1024 * 1024;

export async function digest(bytes) {
    return Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', bytes)),
        byte => byte.toString(16).padStart(2, '0')).join('');
}

async function download(url, request) {
    const signal = AbortSignal.timeout(22000);
    let current = new URL(url);
    for (let redirects = 0; redirects <= 5; redirects++) {
        if (current.protocol !== 'https:' || !hosts.has(current.hostname) ||
            current.username || current.password || current.port) throw Error('Unexpected feed destination');
        const response = await request(current, {
            signal, redirect: 'manual', headers: { 'User-Agent': 'CoreAML-Sanctions-Refresh/1' },
        });
        if ([301, 302, 303, 307, 308].includes(response.status)) {
            await response.body?.cancel();
            const next = response.headers.get('location');
            if (!next) throw Error('Missing redirect location');
            current = new URL(next, current);
            continue;
        }
        if (!response.ok || !response.body) throw Error('Feed unavailable');
        const reader = response.body.getReader();
        const chunks = [];
        let size = 0;
        try {
            for (;;) {
                const { done, value } = await reader.read();
                if (done) break;
                size += value.byteLength;
                if (size > feedLimit) throw Error('Feed exceeds size limit');
                chunks.push(value);
            }
        } finally {
            await reader.cancel().catch(() => {});
        }
        if (!size) throw Error('Empty feed');
        const bytes = new Uint8Array(size);
        let offset = 0;
        for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
        return {
            text: new TextDecoder('utf-8', { fatal: true }).decode(bytes),
            path: current.pathname,
            metadata: { url, sha256: await digest(bytes) },
        };
    }
    throw Error('Too many redirects');
}

function record(source, reference, name, kind, aliases = [], evidence = {}) {
    name = name.trim().replace(/\s+/g, ' ');
    aliases = [...new Set(aliases.map(alias => alias.trim()).filter(Boolean))].sort();
    if (!reference || reference.length > 150 || !name || name.length > 1000 ||
        aliases.length > 1000 || aliases.some(alias => alias.length > 1000) ||
        !['individual', 'entity', 'vessel', 'aircraft'].includes(kind)) throw Error('Invalid source entry');
    return { source, reference, name, kind, aliases, ...evidence };
}

export function parseUN(text) {
    const xml = new SaxesParser();
    const path = [];
    const entries = [];
    let node = null;
    let field = null;
    xml.on('doctype', () => { throw Error('UN list contains a DTD'); });
    xml.on('opentag', tag => {
        path.push(tag.name);
        if (path.length === 1 && (tag.name !== 'CONSOLIDATED_LIST' || !tag.attributes.dateGenerated)) {
            throw Error('Unknown UN list format');
        }
        const isEntry = path.length === 3 && (
            (path[1] === 'INDIVIDUALS' && tag.name === 'INDIVIDUAL') ||
            (path[1] === 'ENTITIES' && tag.name === 'ENTITY'));
        if (isEntry) node = { kind: tag.name.toLowerCase(), fields: {}, aliases: [] };
        if (!node) return;
        const capture = (path.length === 4 &&
            ['FIRST_NAME', 'SECOND_NAME', 'THIRD_NAME', 'FOURTH_NAME', 'REFERENCE_NUMBER', 'UN_LIST_TYPE'].includes(tag.name)) ||
            (path.length === 5 && path[3] === path[2] + '_ALIAS' && tag.name === 'ALIAS_NAME');
        if (capture) field = { depth: path.length, name: tag.name, value: '' };
    });
    const append = value => { if (field) field.value += value; };
    xml.on('text', append);
    xml.on('cdata', append);
    xml.on('closetag', () => {
        if (node && field?.depth === path.length) {
            if (field.name === 'ALIAS_NAME') node.aliases.push(field.value);
            else node.fields[field.name] = field.value;
            field = null;
        }
        if (node && path.length === 3) {
            const { fields, kind, aliases } = node;
            const name = ['FIRST_NAME', 'SECOND_NAME', 'THIRD_NAME', 'FOURTH_NAME']
                .map(key => fields[key] ?? '').join(' ');
            entries.push(record('UN', fields.REFERENCE_NUMBER, name, kind, aliases, { program: fields.UN_LIST_TYPE ?? null }));
            node = null;
        }
        path.pop();
    });
    xml.write(text).close();
    if (new Set(entries.map(entry => entry.kind)).size !== 2) throw Error('UN list lacks expected sections');
    return entries;
}

function csvRows(text, width) {
    const { data, errors } = Papa.parse(text.replace(/[\x1a\r\n]+$/, ''), { delimiter: ',', skipEmptyLines: true });
    if (errors.length || !data.length) throw Error('Invalid OFAC CSV');
    return data.map(row => {
        const cells = row.map(value => value.trim());
        if (cells.length !== width || !/^\d+$/.test(cells[0])) throw Error('Unknown OFAC CSV layout');
        return cells;
    });
}

export function parseOFAC(source, primary, aliasFeed) {
    const folder = path => path.slice(0, path.lastIndexOf('/'));
    if (!primary.path.startsWith('/Published/') || folder(primary.path) !== folder(aliasFeed.path)) {
        throw Error('OFAC primary and alias releases differ');
    }
    const entries = new Map();
    for (const [key, name, type, program] of csvRows(primary.text, 12)) {
        if (entries.has(key)) throw Error('Duplicate OFAC primary record');
        entries.set(key, { name, kind: type === '-0-' ? 'entity' : type, program, aliases: [] });
    }
    for (const [key, , , alias] of csvRows(aliasFeed.text, 5)) {
        if (!entries.has(key) || !alias || alias === '-0-') throw Error('Unpaired OFAC alias');
        entries.get(key).aliases.push(alias);
    }
    return Array.from(entries, ([key, { name, kind, aliases, program }]) =>
        record(source, key, name, kind, aliases, { program }));
}

export function parseNigeria(text) {
    const entries = [];
    let cells = null;
    let inCell = false;
    let link = null;
    const parser = new Parser({
        onopentag(tag, attrs) {
            if (tag === 'tr') { cells = []; link = null; }
            else if (tag === 'td' && cells) { cells.push(''); inCell = true; }
            else if (tag === 'a' && inCell && /^\/(Ind|Ent)SancDetails\?id=\d+$/.test(attrs.href)) link = attrs.href;
        },
        ontext(value) { if (inCell) cells[cells.length - 1] += value; },
        onclosetag(tag) {
            if (tag === 'td') inCell = false;
            if (tag !== 'tr' || !cells) return;
            if (link) {
                if (cells.length !== 5 || !/^\d+$/.test(cells[0].trim())) throw Error('Unknown Nigeria list format');
                const kind = link.startsWith('/Ind') ? 'individual' : 'entity';
                entries.push(record('NIGERIA', link, cells[1], kind, [], {
                    designation_reference: kind === 'individual' ? cells[2].trim() : null,
                    source_record: 'https://nigsac.gov.ng' + link,
                }));
            }
            cells = null;
            inCell = false;
        },
    });
    parser.end(text);
    if (new Set(entries.map(entry => entry.kind)).size !== 2) throw Error('Nigeria list lacks expected sections');
    return entries;
}

export async function collectSnapshot(request = fetch) {
    async function collect(keys, failure, parse) {
        try {
            const feeds = await Promise.all(keys.map(key => download(urls[key], request)));
            return { entries: parse(...feeds), files: keys.map((key, i) => [key, feeds[i].metadata]) };
        } catch (error) {
            throw Object.assign(Error(failure), { feedError: error instanceof Error ? error.message : 'Unknown failure' });
        }
    }
    const groups = await Promise.all([
        collect(['un'], 'UN_FEED', un => parseUN(un.text)),
        collect(['sdn', 'sdn_alias'], 'OFAC_SDN_FEED', (primary, aliases) => parseOFAC('OFAC_SDN', primary, aliases)),
        collect(['non_sdn', 'non_sdn_alias'], 'OFAC_NON_SDN_FEED', (primary, aliases) => parseOFAC('OFAC_NON_SDN', primary, aliases)),
        collect(['nigeria'], 'NIGERIA_FEED', nigeria => parseNigeria(nigeria.text)),
    ]);
    const entries = groups.flatMap(group => group.entries);
    const keys = new Set(entries.map(entry => JSON.stringify([entry.source, entry.reference])));
    if (keys.size !== entries.length || entries.length > 100000) throw Error('SNAPSHOT_VALIDATION');
    const retrieved_at = new Date().toISOString();
    const files = Object.fromEntries(groups.flatMap(group => group.files));
    const bytes = new TextEncoder().encode(JSON.stringify({ entries, files, retrieved_at }));
    if (bytes.byteLength > 32 * 1024 * 1024) throw Error('SNAPSHOT_VALIDATION');
    return { entries, files, retrieved_at, sha256: await digest(bytes),
        counts: Object.fromEntries(groups.map(group => [group.entries[0].source, group.entries.length])) };
}
