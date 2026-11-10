#!/usr/bin/env python3
"""Fetch official sanctions lists and compare names offline for a local pilot."""

import argparse
from concurrent.futures import ThreadPoolExecutor
import csv
from datetime import datetime, timezone
from hashlib import sha256
from html.parser import HTMLParser
from io import StringIO
import json
import os
from pathlib import Path
import re
import tempfile
import unicodedata
from urllib.parse import urlparse
from urllib.request import HTTPRedirectHandler, Request, build_opener
import xml.etree.ElementTree as ET


UN = "https://scsanctions.un.org/resources/xml/en/consolidated.xml"
OFAC = "https://www.treasury.gov/ofac/downloads/"
NIGERIA = "https://nigsac.gov.ng/IndSancList"
HOSTS = {
    "scsanctions.un.org", "unsolprodfiles.blob.core.windows.net",
    "www.treasury.gov", "ofac.treasury.gov", "sanctionslistservice.ofac.treas.gov",
    "wc2h-sls-prod-public-published.s3.us-gov-west-1.amazonaws.com",
    "nigsac.gov.ng",
}
MAX_BYTES = 32 * 1024 * 1024


class OfficialRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        dest = urlparse(newurl)
        if dest.scheme != "https" or dest.hostname not in HOSTS or dest.username:
            raise ValueError("Unexpected feed redirect")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def download(url):
    with build_opener(OfficialRedirect()).open(
        Request(url, headers={"User-Agent": "CoreAML-Sanctions-Pilot/1"}), timeout=20
    ) as response:
        content = response.read(MAX_BYTES + 1)
        if not content or len(content) > MAX_BYTES:
            raise ValueError("Feed response is empty or exceeds the size limit")
        return content, urlparse(response.url).path


def record(source, key, name, kind, aliases=(), **evidence):
    if not key or not name.strip():
        raise ValueError(f"Missing name or source reference in {source}")
    return dict(source=source, reference=key, name=" ".join(name.split()),
                kind=kind, aliases=sorted({a.strip() for a in aliases if a.strip()}),
                **evidence)


def parse_un(content):
    if re.search(rb"<!\s*(DOCTYPE|ENTITY)\b", content, re.I):
        raise ValueError("Unexpected declarations in UN XML")
    root = ET.fromstring(content)
    if root.tag != "CONSOLIDATED_LIST" or not root.get("dateGenerated"):
        raise ValueError("Unrecognized UN list")
    entries = []
    for container, tag in (("INDIVIDUALS", "INDIVIDUAL"), ("ENTITIES", "ENTITY")):
        nodes = root.findall(f"./{container}/{tag}")
        if not nodes:
            raise ValueError(f"UN list lacks {container}")
        for node in nodes:
            name = " ".join(node.findtext(field) or "" for field in
                            ("FIRST_NAME", "SECOND_NAME", "THIRD_NAME", "FOURTH_NAME"))
            entries.append(record(
                "UN", node.findtext("REFERENCE_NUMBER"), name, tag.lower(),
                (alias.findtext("ALIAS_NAME") or "" for alias in node.findall(tag + "_ALIAS")),
                program=node.findtext("UN_LIST_TYPE"),
            ))
    return entries


def csv_rows(content, size):
    data = content.decode("utf-8-sig").rstrip("\x1a\r\n")
    rows = [[cell.strip() for cell in row] for row in csv.reader(StringIO(data), strict=True) if row]
    if not rows or any(len(row) != size or not row[0].isdigit() for row in rows):
        raise ValueError("Unrecognized OFAC CSV layout")
    return rows


def parse_ofac(source, primary, aliases):
    entries = {}
    for key, name, kind, program, *_ in csv_rows(primary, 12):
        if key in entries:
            raise ValueError("Duplicate OFAC primary reference")
        entries[key] = record(source, key, name, kind if kind != "-0-" else "entity", program=program)
    for key, _, _, alias, _ in csv_rows(aliases, 5):
        if key not in entries or not alias or alias == "-0-":
            raise ValueError("Unpaired OFAC alias record")
        entries[key]["aliases"].append(alias)
    for entry in entries.values():
        entry["aliases"] = sorted(set(entry["aliases"]))
    return list(entries.values())


class NigeriaList(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.cells = None
        self.in_cell = False
        self.link = None
        self.entries = []

    def handle_starttag(self, tag, attrs):
        if tag == "tr":
            self.cells, self.link = [], None
        elif tag == "td" and self.cells is not None:
            self.cells.append("")
            self.in_cell = True
        elif tag == "a" and self.in_cell:
            href = dict(attrs).get("href", "")
            if re.fullmatch(r"/(?:Ind|Ent)SancDetails\?id=\d+", href):
                self.link = href

    def handle_data(self, data):
        if self.in_cell:
            self.cells[-1] += data

    def handle_endtag(self, tag):
        if tag == "td":
            self.in_cell = False
        elif tag == "tr" and self.cells is not None:
            if self.link:
                if len(self.cells) != 5 or not self.cells[0].strip().isdigit():
                    raise ValueError("Unrecognized Nigeria sanctions table")
                _, name, ref, _, _ = self.cells
                kind = "individual" if self.link.startswith("/Ind") else "entity"
                self.entries.append(record(
                    "NIGERIA", self.link, name, kind,
                    designation_reference=ref.strip() if kind == "individual" else None,
                    source_record="https://nigsac.gov.ng" + self.link,
                ))
            self.cells, self.in_cell = None, False


def refresh(destination):
    urls = {
        "un": UN, "sdn": OFAC + "sdn.csv", "sdn_alias": OFAC + "alt.csv",
        "non_sdn": OFAC + "consolidated/cons_prim.csv",
        "non_sdn_alias": OFAC + "consolidated/cons_alt.csv", "nigeria": NIGERIA,
    }
    with ThreadPoolExecutor(max_workers=len(urls)) as workers:
        downloads = workers.map(download, urls.values())
        files = {key: (data, urls[key], path)
                 for key, (data, path) in zip(urls, downloads)}
    # OFAC publishes these paired files under the same release directory.
    for primary, alias in (("sdn", "sdn_alias"), ("non_sdn", "non_sdn_alias")):
        paths = [files[key][2] for key in (primary, alias)]
        if not all(p.startswith("/Published/") for p in paths) or (
            paths[0].rsplit("/", 1)[0] != paths[1].rsplit("/", 1)[0]
        ):
            raise ValueError("OFAC primary and alias files could not be tied to the same release")
    nigeria = NigeriaList()
    nigeria.feed(files["nigeria"][0].decode("utf-8-sig"))
    nigeria.close()
    if {entry["kind"] for entry in nigeria.entries} != {"entity", "individual"}:
        raise ValueError("Nigeria page did not contain both sanctions tables")
    entries = (parse_un(files["un"][0])
               + parse_ofac("OFAC_SDN", files["sdn"][0], files["sdn_alias"][0])
               + parse_ofac("OFAC_NON_SDN", files["non_sdn"][0], files["non_sdn_alias"][0])
               + nigeria.entries)
    if len({(e["source"], e["reference"]) for e in entries}) != len(entries):
        raise ValueError("Duplicate source reference")
    timestamp = datetime.now(timezone.utc).isoformat()
    metadata = {key: {"url": url, "sha256": sha256(data).hexdigest()}
                for key, (data, url, _) in files.items()}
    snapshot = dict(version=1, retrieved_at=timestamp, files=metadata, entries=entries)
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=destination.parent,
                                     delete=False) as output:
        staging = Path(output.name)
        try:
            json.dump(snapshot, output, ensure_ascii=False)
            output.close()
            os.replace(staging, destination)
        finally:
            staging.unlink(missing_ok=True)
    return {source: sum(e["source"] == source for e in entries)
            for source in sorted({e["source"] for e in entries})}


def normalized(name):
    return re.findall(r"[^\W_]+", unicodedata.normalize("NFKC", name).casefold())


def screen(snapshot, name):
    tokens = normalized(name)
    if not tokens or len(name) > 300 or snapshot["version"] != 1:
        raise ValueError("Expected a valid name and version 1 snapshot")
    matches = []
    for entry in snapshot["entries"]:
        for candidate in [entry["name"], *entry["aliases"]]:
            words = normalized(candidate)
            if tokens == words or (entry["kind"] == "individual" and sorted(tokens) == sorted(words)):
                matches.append({**entry, "matched_name": candidate,
                                "match_basis": "name" if tokens == words else "name_tokens_reordered"})
                break
    return dict(status="POSSIBLE_MATCH" if matches else "NO_NAME_MATCH_IN_SNAPSHOT",
                retrieved_at=snapshot["retrieved_at"], count=len(matches), matches=matches[:25])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("refresh", "screen"))
    parser.add_argument("snapshot", type=Path)
    args = parser.parse_args()
    try:
        if args.action == "refresh":
            result = refresh(args.snapshot)
        else:
            name = input("Name to compare locally: ")
            result = screen(json.loads(args.snapshot.read_text(encoding="utf-8")), name)
        print(json.dumps(result, ensure_ascii=True, indent=2))
    except (ValueError, OSError, KeyError, EOFError, csv.Error, ET.ParseError) as error:
        # Transport exception details may contain temporary signed feed URLs.
        parser.exit(1, f"Sanctions pilot failed ({type(error).__name__}). "
                    "Check feed availability, format and snapshot path.\n")


if __name__ == "__main__":
    main()
