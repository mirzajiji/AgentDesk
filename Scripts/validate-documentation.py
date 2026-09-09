#!/usr/bin/env python3
"""Read-only integrity, traceability, local-link, and Git-ignore checks for B01."""

import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parents[1]
ARCHITECTURE = ROOT / 'Docs/Architecture'
EXPECTED_SHA = 'b7475d91fc2464c790183d82e74024025c17d8cee1120021910549a0f17cfd51'


def require(condition, message):
    if not condition:
        raise ValueError(message)


def main():
    source = (ARCHITECTURE / 'final-architecture.txt').read_bytes()
    require(hashlib.sha256(source).hexdigest() == EXPECTED_SHA, 'Architecture source hash changed')
    manifest = json.loads((ARCHITECTURE / 'coverage.json').read_text())
    require(manifest['source'] == 'final-architecture.txt', 'Unexpected source path')
    require(manifest['sourceSHA256'] == EXPECTED_SHA, 'Manifest source hash mismatch')
    require(manifest['sectionCount'] == 159, 'Expected 159 sections')

    # Numbered examples restart at 1; only the next source section is a heading.
    headings = []
    for line_number, line in enumerate(source.decode('utf-8').splitlines(), 1):
        match = re.fullmatch(r'(\d+)\. (.+)', line)
        if match and int(match[1]) == len(headings) + 1:
            headings.append((int(match[1]), match[2], line_number))
    require(len(headings) == 159, 'Missing source sections')
    require(len(manifest['sections']) == 159, 'Missing or duplicate manifest entries')
    owners = {}
    table = (ARCHITECTURE / 'coverage.md').read_text()
    for entry, heading in zip(manifest['sections'], headings):
        require((entry['section'], entry['title'], entry['sourceLine']) == heading,
                f'Section metadata mismatch: {entry["section"]}')
        page = entry['document']
        require(Path(page).name == page and page.endswith('.md'), f'Invalid owner: {page}')
        owners.setdefault(page, []).append(entry['section'])
        row = (f'| {entry["section"]} | {entry["title"]} | '
               f'[{Path(page).stem}]({page}) | {entry["sourceLine"]} |')
        require(row in table.splitlines(), f'Coverage table mismatch: {entry["section"]}')
    require(len(owners) == manifest['documentCount'] == 34, 'Expected 34 subsystem pages')
    for page, sections in owners.items():
        content = (ARCHITECTURE / page).read_text()
        require('Status:' in content, f'Missing implementation status: {page}')
        match = re.search(r'<!-- Source sections: ([\d,]+) -->', content)
        require(match and [int(n) for n in match[1].split(',')] == sections,
                f'Invalid section ownership: {page}')
        require('(final-architecture.txt)' in content, f'Missing source link: {page}')

    # Section 112 explicitly names these pages; the source hash pins that contract.
    required_pages = ('overview apple-platforms workspaces projects project-memory requirements '
                      'bug-registry execution codex plugins mcp databases workflows security '
                      'permissions persistence run-events remote-access local-network '
                      'device-pairing usage').split()
    require(all((ARCHITECTURE / f'{name}.md').is_file() for name in required_pages),
            'Missing required architecture page')

    markdown = [ROOT / name for name in ['README.md', 'AGENTS.md', 'Data/README.md', 'Workspaces/README.md']]
    markdown += sorted((ROOT / 'Docs').rglob('*.md'))
    links = 0
    for path in markdown:
        content = path.read_text()
        for number, line in enumerate(content.splitlines(), 1):
            require(line == line.rstrip(), f'Trailing whitespace: {path.relative_to(ROOT)}:{number}')
        for target in re.findall(r'\[[^\]]*\]\(([^)]+)\)', content):
            url = urlsplit(target.strip('<>'))
            if url.scheme or url.netloc or not url.path:
                continue
            resolved = (path.parent / unquote(url.path)).resolve()
            require(resolved.is_relative_to(ROOT), f'Local link leaves repository: {path}: {target}')
            require(resolved.exists(), f'Broken local link: {path}: {target}')
            links += 1

    ignored = ['.DS_Store', 'Packages/Example/.build/output', 'DerivedData/output',
               'Workspaces/example/workspace.json', 'Data/runtime.sqlite',
               'TestResults/example.xcresult/Info.plist', 'Deliverables/export.zip',
               'AgentDesk.xcodeproj/xcuserdata/example.xcuserdatad/state',
               '.env', '.env.local', 'example.p12', 'example.p8', 'example.key',
               'example.mobileprovision', 'example.sqlite-wal', 'example.db-shm']
    trackable = [str(path.relative_to(ROOT)) for path in markdown]
    trackable += ['.gitignore', 'Scripts/validate-documentation.py',
                  'Docs/Architecture/final-architecture.txt', 'Docs/Architecture/coverage.json',
                  'AgentDesk/AgentDeskApp.swift',
                  'AgentDesk.xcodeproj/xcshareddata/xcschemes/AgentDesk.xcscheme']
    result = subprocess.run(['git', 'check-ignore', '--no-index', '--stdin'], cwd=ROOT,
                            input='\n'.join(ignored + trackable) + '\n',
                            text=True, capture_output=True)
    require(result.returncode in (0, 1), f'Git ignore check failed: {result.stderr.strip()}')
    require(set(result.stdout.splitlines()) == set(ignored), 'Git ignore/trackable expectations failed')
    print(f'PASS: source SHA-256; 159 sections; 34 owners; 21 required pages; '
          f'{len(markdown)} Markdown files; {links} local file links; '
          f'{len(ignored)} ignored and {len(trackable)} trackable paths.')
    print('Documentation checks only; no product unit, build, or Simulator coverage is implied.')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, OSError) as error:
        print(f'FAIL: {error}', file=sys.stderr)
        sys.exit(1)
