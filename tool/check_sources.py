#!/usr/bin/env python3
# Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
"""Offline structural checks. These are not a Flutter/Kotlin compiler."""
from pathlib import Path
import json
import subprocess
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
files = [p for p in root.rglob('*') if p.is_file() and not any(v in p.parts for v in ['node_modules', '.dart_tool', 'build', '.gradle'])]
for path in files:
    if path.suffix == '.json':
        json.loads(path.read_text())
    elif path.suffix == '.xml':
        ET.parse(path)
for path in (root / 'backend/functions/src').glob('*.js'):
    subprocess.run(['node', '--check', str(path)], check=True)
assert (root / 'android/gradle/wrapper/gradle-wrapper.jar').read_bytes()[:2] == b'PK'
assert 'CAPTURE_STOPPED' in (root / 'android/webrtc_patch/GetUserMediaImpl.java').read_text()
assert '1.6.2+hotfix.3' in (root / 'pubspec.yaml').read_text()
print('JSON/XML/JavaScript syntax, wrapper and patch checks passed.')
print('Not performed by this script: flutter analyze, flutter test, Android build, RTDB emulator, or physical-device tests.')
