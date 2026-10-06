#!/usr/bin/env python3
# Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
"""Derive both Dart config files from the Firebase console's Android JSON files.
No service account or FCM server key is ever written to the application.
"""
import argparse
import json
from pathlib import Path
import shutil
from urllib.parse import urlparse

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--host', type=Path, required=True)
parser.add_argument('--client', type=Path, required=True)
parser.add_argument('--database-url', required=True)
args = parser.parse_args()
url = urlparse(args.database_url)
if url.scheme != 'https' or not url.hostname or not url.hostname.endswith(('.firebasedatabase.app', '.firebaseio.com')) or url.username or url.password:
    parser.error('Use your exact HTTPS Firebase Realtime Database URL')
configs = {}
project_ids = set()
for role in ['host', 'client']:
    source = getattr(args, role).resolve()
    document = json.loads(source.read_text(encoding='utf-8'))
    info = document['project_info']
    project_ids.add(info['project_id'])
    clients = [c for c in document['client'] if c['client_info']['android_client_info']['package_name'] == f'com.familyhelper.{role}']
    if len(clients) != 1:
        parser.error(f'{role}: JSON must contain exactly com.familyhelper.{role}')
    client = clients[0]
    configs[role] = (source, {
        'FIREBASE_API_KEY': client['api_key'][0]['current_key'],
        'FIREBASE_APP_ID': client['client_info']['mobilesdk_app_id'],
        'FIREBASE_MESSAGING_SENDER_ID': str(info['project_number']),
        'FIREBASE_PROJECT_ID': info['project_id'],
        'FIREBASE_DATABASE_URL': args.database_url.rstrip('/'),
    })
if len(project_ids) != 1:
    parser.error('Host and client must belong to the same Firebase project')
for role, (source, config) in configs.items():
    destination = root / 'android' / 'app' / 'src' / role / 'google-services.json'
    if source != destination.resolve():
        shutil.copyfile(source, destination)
    (root / 'config' / f'{role}.json').write_text(json.dumps(config, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
print('Configured host and client. Next: deploy backend and configure release signing (README).')
