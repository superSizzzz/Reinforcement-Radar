"""Supported game inputs and Lua resource archive encoding."""
import hashlib
import os
from pathlib import Path
import struct

ROOT = Path(__file__).resolve().parents[1]
# Game install and a LuaJIT binary. The defaults below reflect the machine this
# was developed on; override them on any other setup:
#   HD2_GAME_ROOT  the Helldivers 2 install directory
#   HD2_LUAJIT     a luajit executable -- the build only compiles with it, so
#                  any LuaJIT 2.1 build works
GAME = Path(os.environ.get(
    'HD2_GAME_ROOT', r'D:\SteamLibrary\steamapps\common\Helldivers 2'))
LUA = Path(os.environ.get(
    'HD2_LUAJIT', r'D:\coding\KnowYourConstellation-main\tools\src\LuaJIT\src\luajit.exe'))
EXE_SHA = 'F5FEE03DCFDB2E553A4752C283590950AC13316B376D8196AA556FF0400D5F06'
GAME_DLL_SHA = '2E2C3B7C2500646DADD5F2B4C6E0504DBB7E7896139F64CDDC0D1813C718F51E'
# PE values the reader checks at runtime. Stored here so the build can assert
# they match the installed game, catching a drift before it reaches the game.
GAME_DLL_TIMESTAMP = 1790161983
GAME_DLL_IMAGE_SIZE = 74727424
ARCHIVE = '9ba626afa44a3aa3.patch_0'
TYPE = 0xA14E8DFA2CD117E2


def sha(data):
    return hashlib.sha256(data).hexdigest().upper()


def pe_fingerprint(path):
    """(TimeDateStamp, SizeOfImage) from a PE image."""
    data = path.read_bytes()
    if data[:2] != b'MZ':
        raise ValueError('%s is not a PE image' % path)
    pe = struct.unpack_from('<I', data, 60)[0]
    if data[pe:pe + 4] != b'PE\0\0':
        raise ValueError('%s has no PE signature' % path)
    timestamp = struct.unpack_from('<I', data, pe + 8)[0]
    image_size = struct.unpack_from('<I', data, pe + 24 + 56)[0]
    return timestamp, image_size


def resource_hash(name):
    """MurmurHash64A, seed 0. Must match the loader's own hasher exactly."""
    data = name.encode('utf-8')
    mask, mix = (1 << 64) - 1, 0xC6A4A7935BD1E995
    value = len(data) * mix & mask
    end = len(data) // 8 * 8
    for (word,) in struct.iter_unpack('<Q', data[:end]):
        word = word * mix & mask
        word ^= word >> 47
        value = (value ^ (word * mix & mask)) * mix & mask
    if data[end:]:
        value = (value ^ int.from_bytes(data[end:], 'little')) * mix & mask
    value ^= value >> 47
    value = value * mix & mask
    return value ^ (value >> 47)


def make_archive(resources):
    if not resources:
        raise ValueError('An archive needs at least one resource')
    count = len(resources)
    offset = (104 + 80 * count + 15) & ~15
    entries, body = bytearray(), bytearray(offset)
    for index, (name, resource) in enumerate(sorted(resources.items())):
        entries += struct.pack('<7Q6I', name, TYPE, offset, 0, 0, 0, 0,
                               len(resource), 0, 0, 16, 16, index)
        body += resource
        body += b'\0' * (-len(body) % 16)
        offset = len(body)
    header = struct.pack('<III20sQQ24s', 0xF0000011, 1, count, b'', offset, 0, b'')
    types = struct.pack('<IIQIIII', 0, 0, TYPE, count, 0, 16, 16)
    body[:104 + len(entries)] = header + types + entries
    return bytes(body)
