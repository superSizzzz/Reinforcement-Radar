"""Create a mod-manager ZIP from verified build outputs."""
import hashlib
import json
from pathlib import Path
import zipfile


def digest(data):
    return hashlib.sha256(data).hexdigest().upper()


def package_release(root, build, report):
    deployment = {'data/' + report['archive']: build / report['archive']}
    for suffix in ('.stream', '.gpu_resources'):
        deployment['data/' + report['archive'] + suffix] = build / (report['archive'] + suffix)

    files = {}
    for destination, source in deployment.items():
        data = source.read_bytes()
        if digest(data) != report['files'][destination]:
            raise ValueError('Build output changed before packaging: ' + destination)
        files[destination] = data

    display_name = report['name'] + ' - ' + report['display_version']
    description = report['description']
    manifest = {
        'Version': 1,
        'Guid': report['guid'],
        'Name': display_name,
        'Description': description,
        'Options': [{
            'Name': display_name,
            'Description': description,
            'Include': ['data'],
        }],
    }
    files['manifest.json'] = (json.dumps(manifest, indent=2) + '\n').encode()
    files[report['slug'] + '-README.txt'] = report['readme'].encode()
    files[report['slug'] + '-manifest.json'] = (
        json.dumps({
            'name': report['name'],
            'revision': report['revision'],
            'display_version': report['display_version'],
            'steam_build': report['steam_build'],
            'game_exe_sha256': report['game_exe_sha256'],
            'game_dll_sha256': report['game_dll_sha256'],
            'game_dll_timestamp': report['game_dll_timestamp'],
            'game_dll_image_size': report['game_dll_image_size'],
            'read_only': True,
            'network_calls': False,
            'gameplay_memory_writes': False,
            'resource_sha256': report['resource_sha256'],
            'files': {name: digest(data) for name, data in files.items()},
        }, indent=2) + '\n').encode()

    output = root / 'build' / (report['name'].replace(' ', '-') + '-' + report['display_version'] + '.zip')
    with zipfile.ZipFile(output, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name, data in sorted(files.items()):
            info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            archive.writestr(info, data)
    return output
