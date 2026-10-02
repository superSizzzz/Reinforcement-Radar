"""Build and verify a Reinforcement Radar package.

Two variants: the cooldown reader (default) and a module-lookup diagnostic
(--diag). Both share the same read-only layer and the same build guarantees.
"""
import argparse
import json
import os
from pathlib import Path
import struct
import subprocess
import sys

sys.dont_write_bytecode = True

from archive import (GAME, LUA, EXE_SHA, GAME_DLL_SHA, GAME_DLL_TIMESTAMP,
                     GAME_DLL_IMAGE_SIZE, ARCHIVE, sha, make_archive,
                     resource_hash, pe_fingerprint)
import module as mod
from package import package_release

ROOT = Path(__file__).resolve().parents[1]
GUID = '7d5c3a91-4e62-4b08-9f73-2a1e6c8d0457'
DIAG_GUID = '2e8b4f60-9c17-4d5a-8b31-6f420e9a7c53'
STEAM_BUILD = 25480438

SUMMARY = ('Reads the mission\'s native shared enemy reinforcement cooldown and writes it '
           'to a log. Reader stage: no HUD yet. Read-only, no gameplay effect, client-side only.')
DIAG_SUMMARY = ('Diagnostic build: traces the game.dll module lookup chain and reports every '
                'step, including raw value types. Read-only. No gameplay effect.')

READ_ME = """Reinforcement Radar - reader stage
==================================

READER STAGE. This build reads the reinforcement cooldown and writes a log.
It draws nothing on screen yet.

REQUIRES: Bingus Shared Loader v15 or newer / API 1.

HOW TO RUN
  1. Close Helldivers 2.
  2. Import this ZIP with Arsenal or HD2MM, enable it, Deploy.
  3. Launch the game, stay on the ship a few seconds.
  4. Enter a mission and play normally for a minute or two.
  5. Exit the game.

WHERE THE LOG GOES
  %LOCALAPPDATA%/CowboyBingus/Helldivers2/Logs/ReinforcementRadar.log
  Fallbacks, in order: C:/ReinforcementRadar.log, then the game working directory.

WHAT THE LOG CONTAINS
  A VERIFY section first. If the game build does not match the offsets it says
  so and stops; it never reports numbers it cannot trust.

  Then SAMPLE blocks recording the whole resolved chain:
    status          READY / COOLDOWN / PENDING / PAUSED / UNKNOWN / UNAVAILABLE
    authoritative   whether this client owns the cooldown timer
    seconds         the countdown, only present on the authoritative client
    raw_remaining   native cooldown remaining, before the rate is applied
    rate            cooldown rate; expected near 1.0, not exactly 1.0
    fraction        0..1 normalized ratio (the only value clients receive)
    pending         queued reinforcement requests
    derived         ceil(raw_remaining / rate), shown so the arithmetic is checkable

  A block is written on every state change, plus a heartbeat while a cooldown
  counts down. Transitions are the interesting events.

SAFETY
  Read-only. The build refuses to assemble if any write, protection or
  allocation API appears in the source.
"""

DIAG_READ_ME = """Reinforcement Radar - diagnostic build
=======================================

This build does not read the cooldown. It traces the game.dll module lookup
and records every step, so a silent failure can be pinpointed.

REQUIRES: Bingus Shared Loader v15 or newer / API 1.

HOW TO RUN
  1. Close Helldivers 2.
  2. Import this ZIP, enable it, Deploy.
  3. Launch the game. Stay on the ship for about 10 seconds. That is enough --
     enter a mission if you like, but it is not required.
  4. Exit the game.

WHERE THE LOG GOES
  %LOCALAPPDATA%/CowboyBingus/Helldivers2/Logs/ReinforcementRadarDiag.log

WHAT IT REPORTS
  - ffi.abi results and whether kernel32 loads
  - the raw return type of GetModuleHandleA for several name spellings, and
    what tonumber() makes of each, because the reader normalises the handle
    through tonumber and a table or cdata that does not convert collapses to nil
  - a wide-string attempt, in case the module registers under GetModuleHandleW
  - GetLastError after the failed lookup
  - the reader API's own view: api.module('game.dll'), api.module(nil), and a
    test read at the executable base

SAFETY
  Read-only. No write, protection or allocation API appears in the source.
"""


def run(arguments):
    env = dict(os.environ, LUA_PATH=str(LUA.parent / '?.lua') + ';;')
    process = subprocess.run([str(a) for a in arguments], capture_output=True, text=True, env=env)
    if process.returncode:
        raise RuntimeError((process.stdout or '') + (process.stderr or ''))
    return process.stdout


def syntax_check(path, label):
    run([LUA, '-e', 'assert(loadfile([[' + str(path) + ']]), "%s")' % label])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--diag', action='store_true',
                        help='Build the module-lookup diagnostic instead of the reader')
    parser.add_argument('--skip-game-check', action='store_true',
                        help='Skip the installed-game checks (offline work only)')
    args = parser.parse_args()

    if args.diag:
        target_module, impl_module = mod.DIAG_MODULE, mod.DIAG_IMPL
        revision, guid = mod.DIAG_REVISION, DIAG_GUID
        display_name, slug = 'Reinforcement Radar Diag', 'ReinforcementRadarDiag'
        description, readme = DIAG_SUMMARY, DIAG_READ_ME
        build_sources = ('read_api', 'diag', 'install_diag')
        assembly = lambda: mod.wrapper_diag(ROOT)
    else:
        target_module, impl_module = mod.MODULE, mod.IMPL
        revision, guid = mod.REVISION, GUID
        display_name, slug = 'Reinforcement Radar', 'ReinforcementRadar'
        description, readme = SUMMARY, READ_ME
        build_sources = ('read_api', 'reinforcement', 'hud', 'install')
        assembly = lambda: mod.wrapper(ROOT, GAME_DLL_SHA, EXE_SHA)

    build = ROOT / 'build'
    build.mkdir(parents=True, exist_ok=True)

    # 1. Sources must parse under the game's Lua 5.1 dialect.
    for name in build_sources:
        syntax_check(ROOT / 'src' / (name + '.lua'), name)
    print('PASS: all sources parse under LuaJIT 5.1')

    # 2. The installed game must be the build the offsets belong to.
    game_report = 'skipped'
    if not args.skip_game_check:
        for filename, expected in (('bin/helldivers2.exe', EXE_SHA),
                                   ('data/game/game.dll', GAME_DLL_SHA)):
            actual = sha((GAME / filename).read_bytes())
            if actual != expected:
                raise SystemExit('Unsupported game build: %s is %s, expected %s'
                                 % (filename, actual, expected))
        timestamp, image_size = pe_fingerprint(GAME / 'data/game/game.dll')
        if timestamp != GAME_DLL_TIMESTAMP or image_size != GAME_DLL_IMAGE_SIZE:
            raise SystemExit('PE fingerprint drift: timestamp=%s image_size=%s '
                             '(reader expects %s / %s)'
                             % (timestamp, image_size, GAME_DLL_TIMESTAMP, GAME_DLL_IMAGE_SIZE))
        game_report = 'verified (exe + game.dll + PE fingerprint)'
    print('PASS: game build ' + game_report)

    # 3. Assemble the wrapper; also enforces the side-effect denylist.
    source = build / 'mod.wrapper.lua'
    source.write_text(assembly(), encoding='utf-8', newline='\n')
    print('PASS: wrapper assembled, no forbidden side-effect API present')

    # 4. Compile to bytecode in the mode the game loads.
    compiled = build / 'mod.ljbc'
    run([LUA, '-bsdW', source, compiled])
    code = compiled.read_bytes()
    if code[:5] != b'\x1bLJ\x02\x02':
        raise SystemExit('Unexpected bytecode mode: %r' % code[:5])
    resource = struct.pack('<II', len(code), 2) + code
    (build / 'mod.lua.main').write_bytes(resource)
    print('PASS: compiled %d bytes of bytecode' % len(code))

    # 5. Two resources; the entry must stay plaintext or discovery skips it.
    entry = mod.entry_source(target_module, impl_module)
    entry_first = entry.split('\n')[0]
    if entry_first != '-- HD2-Addon: ' + target_module:
        raise SystemExit('entry declaration malformed: ' + repr(entry_first))
    if len(entry_first.encode()) + 1 > 256:
        raise SystemExit('entry declaration exceeds 256 bytes')
    entry_bytes = entry.encode('utf-8')
    if b'\0' in entry_bytes:
        raise SystemExit('entry must be plaintext without NUL bytes')
    (build / 'entry.lua').write_text(entry, encoding='utf-8', newline='\n')
    entry_resource = struct.pack('<II', len(entry_bytes), 2) + entry_bytes

    entry_key = resource_hash(target_module)
    impl_key = resource_hash(impl_module)
    if entry_key == impl_key:
        raise SystemExit('entry and impl resource names collide')
    resources = {entry_key: entry_resource, impl_key: resource}
    print('PASS: plaintext entry -> ' + entry_first)
    print('PASS: entry key %016x, impl key %016x' % (entry_key, impl_key))

    # 6. Emit archive and sidecars.
    data = {ARCHIVE: make_archive(resources),
            ARCHIVE + '.stream': b'',
            ARCHIVE + '.gpu_resources': b''}
    for name, payload in data.items():
        (build / name).write_bytes(payload)

    # 7. Read the archive back and confirm the structure the loader expects.
    #    The window is 256 bytes because the declaration line alone is longer
    #    than 40, which is how an earlier readback check produced a false alarm.
    written = (build / ARCHIVE).read_bytes()
    if struct.unpack_from('<III', written) != (0xF0000011, 1, 2):
        raise SystemExit('archive header is not a two-resource archive')
    types, count = struct.unpack_from('<I', written, 4)[0], struct.unpack_from('<I', written, 8)[0]
    table_start = 72 + 32 * types
    seen = {}
    for index in range(count):
        row = written[table_start + index * 80: table_start + index * 80 + 80]
        key = struct.unpack_from('<Q', row, 0)[0]
        offset = struct.unpack_from('<Q', row, 16)[0]
        body_length = struct.unpack_from('<I', written, offset)[0]
        seen[key] = written[offset + 8: offset + 8 + min(body_length, 256)]
    if set(seen) != {entry_key, impl_key}:
        raise SystemExit('archive entries do not match the two expected keys')
    if not seen[entry_key].startswith(b'-- HD2-Addon: ' + target_module.encode()):
        raise SystemExit('entry does not begin with its declaration: %r' % seen[entry_key])
    if not seen[impl_key].startswith(b'\x1bLJ'):
        raise SystemExit('impl is not bytecode: %r' % seen[impl_key][:8])
    print('PASS: archive readback confirms plaintext entry + compiled impl')

    files = {('data/' + name): sha(payload) for name, payload in data.items()}
    report = {
        'name': display_name,
        'slug': slug,
        'revision': revision,
        'display_version': revision.lstrip('v'),
        'guid': guid,
        'steam_build': STEAM_BUILD,
        'description': description,
        'readme': readme,
        'module': target_module,
        'impl': impl_module,
        'archive': ARCHIVE,
        'entry_key': '%016x' % entry_key,
        'impl_key': '%016x' % impl_key,
        'resource_sha256': sha(resource),
        'entry_sha256': sha(entry_resource),
        'game_exe_sha256': EXE_SHA,
        'game_dll_sha256': GAME_DLL_SHA,
        'game_dll_timestamp': GAME_DLL_TIMESTAMP,
        'game_dll_image_size': GAME_DLL_IMAGE_SIZE,
        'game_check': game_report,
        'read_only': True,
        'network_calls': False,
        'gameplay_memory_writes': False,
        'forbidden_tokens_checked': list(mod.FORBIDDEN),
        'files': files,
    }
    release = package_release(ROOT, build, report)
    report['release'] = release.name
    report['release_sha256'] = sha(release.read_bytes())
    (build / 'build-report.json').write_text(
        json.dumps(report, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')
    print('Built ' + str(release))


if __name__ == '__main__':
    main()
