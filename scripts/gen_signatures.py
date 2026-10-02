"""Regenerate the signature table in src/reinforcement.lua from the reference.

The signatures are byte-exact guards taken from the reference implementation
(`mods/hd2_local/automaton_reinforcement_cd`), which is validated against the
live game. Transcribing 1 KB of hex by hand produced a one-character error in
guard 7, which only surfaced as a runtime mismatch on the user's machine.

They cannot be verified against game.dll on disk: the code section is packed in
the file and only expands in memory, so the file bytes do not equal the bytes
the reader compares. Copying them from the reference mechanically is therefore
the only reliable route.

This script rewrites the table in place and reports what changed.
"""
import os
import re
import sys
from pathlib import Path

# The reference implementation's extracted profile. This is a development
# artefact -- the plaintext Lua embedded in the reference mod's archive --
# and is deliberately not kept in this repository. Point
# HD2_SIGNATURE_REFERENCE at your copy, or edit the default below. Without it
# this script cannot run, but that is not a problem in practice: the signature
# table it produces is already checked into src/reinforcement.lua.
REFERENCE = Path(os.environ.get(
    'HD2_SIGNATURE_REFERENCE',
    r'D:\coding\HD2Mods\SmokeWatch\reference\enemy_reinforcement_cd.raw.txt'))
TARGET = Path(__file__).resolve().parents[1] / 'src' / 'reinforcement.lua'


def reference_signatures():
    text = REFERENCE.read_text(encoding='utf-8', errors='replace')
    start = text.find('return entry(reader,support,backend,minimap,renderer,{')
    if start < 0:
        raise SystemExit('reference profile not found in ' + str(REFERENCE))
    found = re.findall(r'\["rva"\]=(\d+),\["hex"\]="([0-9a-f]+)"', text[start:])
    if not found:
        raise SystemExit('no signatures parsed from the reference')
    return [(int(rva), hexs) for rva, hexs in found]


def render(signatures):
    lines = ['    signatures = {']
    for rva, hexs in signatures:
        lines.append("        {rva = %d, hex = '%s'}," % (rva, hexs))
    lines.append('    },')
    return '\n'.join(lines)


def main():
    signatures = reference_signatures()
    print('reference signatures: %d' % len(signatures))

    source = TARGET.read_text(encoding='utf-8')
    existing = re.findall(r"\{rva = (\d+), hex = '([0-9a-f]+)'\}", source)
    existing_map = {int(rva): hexs for rva, hexs in existing}
    print('current signatures  : %d' % len(existing))

    for index, (rva, hexs) in enumerate(signatures, 1):
        current = existing_map.get(rva)
        if current is None:
            print('  %d rva=0x%08x NEW  (%d bytes)' % (index, rva, len(hexs) // 2))
        elif current == hexs:
            print('  %d rva=0x%08x keep (%d bytes)' % (index, rva, len(hexs) // 2))
        else:
            print('  %d rva=0x%08x FIX  (%d -> %d bytes)' % (index, rva,
                  len(current) // 2, len(hexs) // 2))

    block = render(signatures)
    pattern = re.compile(r'    signatures = \{.*?\n    \},', re.S)
    if not pattern.search(source):
        raise SystemExit('could not locate the signatures table to replace')
    updated = pattern.sub(lambda _: block, source, count=1)
    if updated == source:
        print('\nno change needed')
        return
    TARGET.write_text(updated, encoding='utf-8', newline='\n')
    print('\nrewrote the signatures table in %s' % TARGET.name)


if __name__ == '__main__':
    main()
