#!/usr/bin/env python3
# Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
"""Cross-platform release build. Requires locally installed Flutter + Android SDK.
This script never deploys Firebase, accepts Android licenses, or creates keys.
"""
from pathlib import Path
import json
import shutil
import subprocess
import sys

if __package__:
    from .release_guard import apk_inspector, check_existing_versions, publish_pair, recover_pending, version_code_from_pubspec
else:
    from release_guard import apk_inspector, check_existing_versions, publish_pair, recover_pending, version_code_from_pubspec


def main(root=None, flutter=None, inspect=None, run_command=None):
    root = root or Path(__file__).resolve().parents[1]
    dist = root / 'dist'
    recover_pending(dist)
    version_code = version_code_from_pubspec((root / 'pubspec.yaml').read_text())
    inspect = inspect or apk_inspector(root)
    # Fail before Flutter can overwrite any existing release output.
    check_existing_versions(dist, version_code, inspect)

    flutter = flutter or shutil.which('flutter')
    if not flutter:
        raise ValueError('Flutter is not on PATH. Install the Flutter SDK and run flutter doctor first.')
    required = ['android/key.properties'] + [f'config/{r}.json' for r in ('host', 'client')] + [f'android/app/src/{r}/google-services.json' for r in ('host', 'client')]
    missing = [p for p in required if not (root / p).is_file()]
    if missing:
        raise ValueError('Missing configuration:\n' + '\n'.join(missing) + '\nSee README.md.')
    for role in ('host', 'client'):
        config = json.loads((root / 'config' / f'{role}.json').read_text())
        if not config or not all(isinstance(v, str) and v for v in config.values()):
            raise ValueError(f'config/{role}.json contains empty values')

    subprocess.run(
        [sys.executable, '-m', 'unittest', 'discover', '-s', 'tool/tests', '-p', 'test_release_guard.py'],
        cwd=root, check=True,
    )
    if run_command is None:
        def run_command(args):
            subprocess.run([flutter, *args], cwd=root, check=True)

    run_command(('pub', 'get'))
    run_command(('analyze',))
    run_command(('test',))
    candidates = {}
    for role in ('host', 'client'):
        run_command(('build', 'apk', '--flavor', role, '--release', '-t', f'lib/main_{role}.dart', f'--dart-define-from-file=config/{role}.json'))
        candidates[role] = root / 'build' / 'app' / 'outputs' / 'flutter-apk' / f'app-{role}-release.apk'
    publish_pair(candidates, dist, version_code, inspect)
    print('Built dist/familyhelper-host.apk and dist/familyhelper-client.apk')


if __name__ == '__main__':
    try:
        main()
    except ValueError as error:
        sys.exit(str(error))
