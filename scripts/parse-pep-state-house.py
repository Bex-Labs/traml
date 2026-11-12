"""Read the published Cabinet table and the two named leadership cards."""
import json
import re
import sys
from html.parser import HTMLParser
from urllib.parse import quote


class Page(HTMLParser):
    def __init__(self, html):
        super().__init__()
        self.tables = []
        self.headings = []
        self.table = self.row = self.tag = self.parts = None
        self.feed(html)

    def handle_starttag(self, tag, attrs):
        if tag == 'table':
            if self.table is not None:
                raise ValueError('Unexpected nested table')
            self.table = []
        elif tag == 'tr' and self.table is not None:
            self.row = []
        elif (tag in ('td', 'th') and self.row is not None) or tag in ('h3', 'h4'):
            self.tag, self.parts = tag, []
        elif tag == 'br' and self.parts is not None:
            self.parts.append(' ')

    def handle_data(self, data):
        if self.parts is not None:
            self.parts.append(data)

    def handle_endtag(self, tag):
        if tag == self.tag:
            value = ' '.join(''.join(self.parts).split())
            if tag in ('h3', 'h4'):
                self.headings.append((tag, value))
            else:
                self.row.append(value)
            self.tag = self.parts = None
        elif tag == 'tr' and self.row is not None:
            self.table.append(self.row)
            self.row = None
        elif tag == 'table' and self.table is not None:
            self.tables.append(self.table)
            self.table = None


def record(page, published, role):
    name = re.sub(r'^(?:(?:Rt\.|Hon\.|Dr\.|Sen\.|Gen\.|Engr\.|Prof\.|Amb\.|Barr\.|Mr\.|Mrs\.|Chief)\s+)+',
                  '', published, flags=re.I)
    name = re.sub(r'\s*(?:\((?:GCFR|GCON|rtd)\)|\bPhD)\s*$', '', name, flags=re.I).strip()
    reference = f'https://statehouse.gov.ng/{page}/#:~:text={quote(published, safe="").replace("-", "%2D")}'
    if not (1 <= len(name) <= 200 and 1 <= len(role) <= 200 and len(reference) <= 500):
        raise ValueError('Invalid State House record')
    return dict(source_reference=reference, full_name=name, public_role=role, jurisdiction='Nigeria')


def extract(cabinet, leadership):
    tables = [t for t in Page(cabinet).tables if t and t[0] == ['S/N', 'Ministry', 'Portfolio', 'Name']]
    if len(tables) != 1:
        raise ValueError('Expected exactly one Cabinet Members table')
    slots = tables[0][1:]
    if not slots or any(len(r) != 4 or r[0] != str(i) or not r[1] or not r[2]
                        for i, r in enumerate(slots, 1)):
        raise ValueError('Unexpected Cabinet Members table rows')
    rows = [record('the-cabinet', name, f'{portfolio} · {ministry}')
            for _, ministry, portfolio, name in slots if name]
    cabinet_count = len(rows)
    if not cabinet_count:
        raise ValueError('No named cabinet entries')
    headings = Page(leadership).headings
    for role in ('President', 'Vice President'):
        names = [headings[i - 1][1] for i, h in enumerate(headings)
                 if h == ('h4', f'{role}, Federal Republic of Nigeria')
                 and i > 0 and headings[i - 1][0] == 'h3']
        if len(names) != 1:
            raise ValueError(f'Expected exactly one {role} profile')
        rows.append(record('people', names[0], role))
    if len({r['source_reference'] for r in rows}) != len(rows):
        raise ValueError('Duplicate State House name reference')
    return dict(rows=rows, named_cabinet_entries=cabinet_count, unnamed_cabinet_slots=len(slots) - cabinet_count)


if __name__ == '__main__':
    try:
        pages = json.load(sys.stdin)
        print(json.dumps(extract(pages['cabinet'], pages['leadership'])))
    except (ValueError, KeyError) as error:
        sys.exit(f'State House source validation failed: {error}')
