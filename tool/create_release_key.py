#!/usr/bin/env python3
# Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
"""Create this project's private Android release identity exactly once.

The password is generated in memory and passed to keytool on stdin, never in
command arguments or output. Both resulting files must be backed up by owner.
"""

from pathlib import Path
import os
import secrets
import shutil
import subprocess
import sys
import tempfile


root = Path(__file__).resolve().parents[1]
android = root / 'android'
keystore = android / 'familyhelper-release.jks'
properties = android / 'key.properties'
if keystore.exists() or properties.exists():
    sys.exit('Release key already exists; refusing to replace either file.')

java_home = os.environ.get('JAVA_HOME')
keytool = (str(Path(java_home) / 'bin' / 'keytool') if java_home else
           shutil.which('keytool'))
if not keytool or not Path(keytool).is_file():
    sys.exit('keytool not found; configure JDK 17 first.')

password = secrets.token_urlsafe(36)
with tempfile.TemporaryDirectory(prefix='.familyhelper-key-', dir=android) as work:
    temporary = Path(work)
    os.chmod(temporary, 0o700)
    new_keystore = temporary / keystore.name
    result = subprocess.run(
        [keytool, '-genkeypair', '-keystore', str(new_keystore),
         '-storetype', 'JKS', '-alias', 'familyhelper', '-keyalg', 'RSA',
         '-keysize', '3072', '-validity', '10000',
         '-dname', 'CN=FamilyHelper Release, O=FamilyHelper, C=TW'],
        input=f'{password}\n{password}\n\n',
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=90,
        check=False,
    )
    if result.returncode != 0 or not new_keystore.is_file():
        sys.exit('keytool did not create a release key; no project files changed.')
    os.chmod(new_keystore, 0o600)

    new_properties = temporary / properties.name
    with new_properties.open('x') as file:
        file.write(
            f'storePassword={password}\n'
            f'keyPassword={password}\n'
            'keyAlias=familyhelper\n'
            f'storeFile={keystore.name}\n'
        )
    os.chmod(new_properties, 0o600)
    if keystore.exists() or properties.exists():
        sys.exit('A release key appeared during creation; refusing to overwrite it.')
    os.link(new_keystore, keystore)
    try:
        os.link(new_properties, properties)
    except OSError:
        if keystore.stat().st_ino == new_keystore.stat().st_ino:
            keystore.unlink()
        raise

print('Created private release keystore and key.properties (mode 0600).')
print('Back up both files securely; losing them prevents signing future updates.')
