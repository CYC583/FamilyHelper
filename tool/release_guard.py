# Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
"""Validate Android release identity before replacing distributable APKs."""

from dataclasses import dataclass
from pathlib import Path
import os
import re
import shutil
import subprocess


ROLES = ('host', 'client')
PENDING_DIR = '.release-transaction'
FINISHED_DIR = '.release-finished'


@dataclass(frozen=True)
class ApkInfo:
    package: str
    version_code: int
    signer: str


def version_code_from_pubspec(content):
    match = re.search(r'^version:\s*[^\s+]+\+(\d+)\s*$', content, re.MULTILINE)
    if not match:
        raise ValueError('pubspec.yaml needs a numeric versionCode after +')
    return int(match.group(1))


def parse_aapt_badging(output):
    match = re.search(r"^package:\s+name='([^']+)'\s+versionCode='(\d+)'", output, re.MULTILINE)
    if not match:
        raise ValueError('Unable to read APK package/versionCode from aapt')
    return match.group(1), int(match.group(2))


def parse_signer_digest(output):
    digests = re.findall(r'^Signer #\d+ certificate SHA-256 digest: ([0-9a-fA-F]+)$', output, re.MULTILINE)
    if len(digests) != 1:
        raise ValueError('Expected exactly one APK signer SHA-256 digest')
    return digests[0].lower()


def android_build_tools(root):
    sdk = os.environ.get('ANDROID_HOME') or os.environ.get('ANDROID_SDK_ROOT')
    if not sdk:
        properties = root / 'android' / 'local.properties'
        if properties.is_file():
            match = re.search(r'^sdk\.dir=(.+)$', properties.read_text(), re.MULTILINE)
            if match:
                sdk = match.group(1).strip()
    if not sdk:
        raise ValueError('Android SDK path unavailable; set ANDROID_HOME')
    versions = sorted((Path(sdk) / 'build-tools').glob('*'), reverse=True)
    for directory in versions:
        aapt = directory / 'aapt'
        apksigner = directory / 'apksigner'
        if aapt.is_file() and apksigner.is_file():
            return aapt, apksigner
    raise ValueError('Android SDK build-tools need aapt and apksigner')


def apk_inspector(root):
    aapt, apksigner = android_build_tools(root)

    def inspect(path):
        badging = subprocess.run(
            [str(aapt), 'dump', 'badging', str(path)],
            check=True, capture_output=True, text=True,
        ).stdout
        certs = subprocess.run(
            [str(apksigner), 'verify', '--print-certs', str(path)],
            check=True, capture_output=True, text=True,
        ).stdout
        package, version_code = parse_aapt_badging(badging)
        return ApkInfo(package, version_code, parse_signer_digest(certs))

    return inspect


def check_existing_versions(dist, target_version_code, inspect):
    """Fail before building if the new APK would not upgrade the dist baseline."""
    old_signers = set()
    for role in ROLES:
        old = dist / f'familyhelper-{role}.apk'
        if not old.is_file():
            continue
        info = inspect(old)
        if info.package != f'com.familyhelper.{role}':
            raise ValueError(f'{old.name} has wrong package: {info.package}')
        if target_version_code <= info.version_code:
            raise ValueError(
                f'{old.name} versionCode {info.version_code} requires a newer '
                f'pubspec.yaml versionCode (now {target_version_code})'
            )
        old_signers.add(info.signer)
    if len(old_signers) > 1:
        raise ValueError('Existing host/client APKs have different signer certificates')


def recover_pending(dist):
    """Restore the old pair after a process interruption or failed publish."""
    finished = dist / FINISHED_DIR
    if finished.exists():
        shutil.rmtree(finished)
    pending = dist / PENDING_DIR
    if not pending.exists():
        return
    if (pending / 'prepared').is_file():
        for role in ROLES:
            backup = pending / f'backup-{role}.apk'
            destination = dist / f'familyhelper-{role}.apk'
            if backup.is_file():
                restored = pending / f'restored-{role}.apk'
                shutil.copy2(backup, restored)
                os.replace(restored, destination)
            else:
                destination.unlink(missing_ok=True)
    # Rename first: interruption during cleanup cannot make a partial backup
    # look like an unfinished transaction on the next invocation.
    os.replace(pending, finished)
    shutil.rmtree(finished)


def publish_pair(candidates, dist, target_version_code, inspect):
    """Inspect both APKs before changing either published destination."""
    recover_pending(dist)
    check_existing_versions(dist, target_version_code, inspect)
    old_signers = {
        inspect(dist / f'familyhelper-{role}.apk').signer
        for role in ROLES if (dist / f'familyhelper-{role}.apk').is_file()
    }
    candidate_signers = set()
    for role in ROLES:
        candidate = candidates[role]
        if not candidate.is_file():
            raise ValueError(f'Expected APK not found: {candidate}')
        info = inspect(candidate)
        if info.package != f'com.familyhelper.{role}':
            raise ValueError(f'{candidate.name} has wrong package: {info.package}')
        if info.version_code != target_version_code:
            raise ValueError(
                f'{candidate.name} versionCode {info.version_code} does not match '
                f'pubspec.yaml versionCode {target_version_code}'
            )
        candidate_signers.add(info.signer)
    if len(candidate_signers) != 1 or (old_signers and candidate_signers != old_signers):
        raise ValueError('New APK signer does not match the existing release signer')

    dist.mkdir(exist_ok=True)
    stage = dist / PENDING_DIR
    stage.mkdir()
    for role in ROLES:
        shutil.copy2(candidates[role], stage / f'familyhelper-{role}.apk')
        old = dist / f'familyhelper-{role}.apk'
        if old.is_file():
            shutil.copy2(old, stage / f'backup-{role}.apk')
    (stage / 'prepared.tmp').write_text('ready')
    os.replace(stage / 'prepared.tmp', stage / 'prepared')
    try:
        for role in ROLES:
            os.replace(stage / f'familyhelper-{role}.apk', dist / f'familyhelper-{role}.apk')
    except OSError:
        recover_pending(dist)
        raise
    finished = dist / FINISHED_DIR
    os.replace(stage, finished)
    shutil.rmtree(finished)
