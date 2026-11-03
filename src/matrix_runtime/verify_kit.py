"""Read-only, externally pinned file-set checkpoint. Not a signature or sandbox."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import sys


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def unique_object(pairs):
    out = {}
    for key, value in pairs:
        if key in out:
            raise ValueError('duplicate JSON key')
        out[key] = value
    return out


def read_json(raw):
    def reject(value):
        raise ValueError('nonfinite JSON constant: ' + value)
    return json.loads(raw, object_pairs_hook=unique_object, parse_constant=reject)


def relative_name(name):
    if not isinstance(name, str) or not name or any(c in name for c in '\\:\r\n\x00'):
        raise ValueError('invalid relative member')
    parsed = PurePosixPath(name)
    if parsed.is_absolute() or any(p in ('', '.', '..') for p in name.split('/')):
        raise ValueError('noncanonical member')
    return parsed


def no_alias(path):
    info = path.lstat()
    if stat.S_ISLNK(info.st_mode) or getattr(info, 'st_file_attributes', 0) & 0x400:
        raise ValueError('symlink/reparse member unsupported')
    return info


def inventory(root):
    root = Path(root).absolute()
    for ancestor in [root, *root.parents]:
        no_alias(ancestor)
    if not root.is_dir():
        raise ValueError('root directory required')
    files, directories, pending = {}, set(), [root]
    while pending:
        parent = pending.pop()
        with os.scandir(parent) as entries:
            for entry in entries:
                path = Path(entry.path)
                name = path.relative_to(root).as_posix()
                relative_name(name)
                info = no_alias(path)
                if stat.S_ISDIR(info.st_mode):
                    directories.add(name)
                    pending.append(path)
                elif stat.S_ISREG(info.st_mode):
                    files[name] = {'bytes': info.st_size, 'sha256': sha(path.read_bytes())}
                else:
                    raise ValueError('special file unsupported')
    return files, directories


def verify(root, expected_manifest_sha):
    if not isinstance(expected_manifest_sha, str) or re.fullmatch('[0-9a-f]{64}', expected_manifest_sha) is None:
        raise ValueError('external lowercase manifest SHA256 required')
    files, directories = inventory(root)
    manifest_name = 'review_manifest.json'
    actual_manifest = files.pop(manifest_name, None)
    if actual_manifest is None or actual_manifest['sha256'] != expected_manifest_sha:
        raise ValueError('externally pinned manifest identity mismatch')
    document = read_json((Path(root) / manifest_name).read_bytes())
    if type(document) is not dict or document.get('schema') != 'diagnostic-review-members-v1':
        raise ValueError('manifest schema')
    expected = document.get('files')
    if type(expected) is not dict or not expected:
        raise ValueError('nonempty files map required')
    expected_directories = set()
    for name, record in expected.items():
        parsed = relative_name(name)
        if name == manifest_name or type(record) is not dict or set(record) != {'bytes', 'sha256'}:
            raise ValueError('member record shape')
        if type(record['bytes']) is not int or record['bytes'] < 0:
            raise ValueError('non-bool member size required')
        if not isinstance(record['sha256'], str) or re.fullmatch('[0-9a-f]{64}', record['sha256']) is None:
            raise ValueError('member hash format')
        expected_directories.update(p.as_posix() for p in parsed.parents if p.as_posix() != '.')
    if files != expected or directories != expected_directories:
        raise ValueError('member bytes/hash/file-or-directory set mismatch')
    return {'member_identity_ok': True, 'indexed_files': len(files),
            'scope': 'static externally pinned local bytes, not independent approval',
            'board_access': False, 'promotion': False}


class JsonParser(argparse.ArgumentParser):
    def error(self, message):
        raise ValueError(message)


def main():
    try:
        parser = JsonParser()
        parser.add_argument('--manifest-sha', required=True)
        args = parser.parse_args()
        print(json.dumps(verify(Path(__file__).resolve().parent, args.manifest_sha)))
        return 0
    except (ValueError, OSError, KeyError, TypeError) as exc:
        print(json.dumps({'member_identity_ok': False, 'error': str(exc)}), file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
