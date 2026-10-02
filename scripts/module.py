"""Assembly of the Reinforcement Radar runtime wrapper.

The addon is discovered by scanning a deployed archive for a plaintext
`-- HD2-Addon: <resource>` declaration in the first 256 bytes of the resource
body. Compiling the entry strips that comment, which makes the addon silently
undiscoverable, so each package ships two resources:

  * `MODULE` (entry) -- plaintext, one declaration line, forwards to the impl
  * `IMPL`   (impl)  -- the compiled wrapper with the actual code

Two variants are built from the same reader: the cooldown reader itself, and a
diagnostic build that traces the module-lookup chain.
"""
REVISION = 'v1.0.0'
MODULE = 'mods/hd2mods/reinforcement_radar'
IMPL = 'mods/hd2mods/reinforcement_radar_impl'

DIAG_REVISION = 'v0.1.0-diag'
DIAG_MODULE = 'mods/hd2mods/reinforcement_radar_diag'
DIAG_IMPL = 'mods/hd2mods/reinforcement_radar_diag_impl'

# Nothing may write, protect or allocate in the game process, and nothing may
# touch networking. The build refuses to assemble if any of these appear, which
# makes "read-only" a build-time guarantee rather than a comment.
FORBIDDEN = (
    'WriteProcessMemory', 'VirtualProtect', 'VirtualAlloc', 'VirtualFree',
    'CreateRemoteThread', 'LoadLibrary', 'CreateProcess',
    'Network.', 'RPC.', "ffi.cast('void (*",
)

UNITS_READER = (
    ('create_api', 'read_api'),
    ('reinforcement', 'reinforcement'),
    ('hud', 'hud'),
    ('install', 'install'),
)

UNITS_DIAG = (
    ('create_api', 'read_api'),
    ('diag', 'diag'),
    ('install', 'install_diag'),
)


def _read_unit(root, filename):
    source = (root / 'src' / (filename + '.lua')).read_text(encoding='utf-8')
    for token in FORBIDDEN:
        if token in source:
            raise ValueError(
                '%s.lua contains a forbidden side-effect API (%s)' % (filename, token))
    return source


def _assemble(root, units, tail):
    pieces = []
    for variable, filename in units:
        pieces.append('local %s = (function()\n%s\nend)()\n'
                      % (variable, _read_unit(root, filename)))
    pieces.append(tail)
    return ''.join(pieces)


def entry_source(module=MODULE, impl=IMPL):
    """The discoverable entry. Must stay plaintext with the declaration on the
    very first line."""
    return '-- HD2-Addon: ' + module + '\n' + 'return require(' + repr(impl).replace('"', "'") + ')\n'


def wrapper(root, game_sha256=None, exe_sha256=None):
    """The cooldown reader plus its HUD."""
    return _assemble(root, UNITS_READER,
                     "install(create_api,reinforcement,hud,{revision='" + REVISION + "'})\n")


def wrapper_diag(root):
    """The module-lookup diagnostic."""
    return _assemble(root, UNITS_DIAG,
                     "install(create_api,diag,{revision='" + DIAG_REVISION + "'})\n")
