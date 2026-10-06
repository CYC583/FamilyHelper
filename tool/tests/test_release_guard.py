# Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
"""Release packaging invariants; no Flutter build or real signing keys needed."""

from pathlib import Path
import importlib
import os
import tempfile
import unittest
from unittest import mock

from tool.release_guard import (
    ApkInfo,
    check_existing_versions,
    parse_aapt_badging,
    parse_signer_digest,
    publish_pair,
    recover_pending,
    version_code_from_pubspec,
)


class ReleaseGuardTests(unittest.TestCase):
    def test_parses_android_tools_output(self):
        package, code = parse_aapt_badging(
            "package: name='com.familyhelper.host' versionCode='2' versionName='1.0.1'\n"
        )
        self.assertEqual((package, code), ('com.familyhelper.host', 2))
        self.assertEqual(
            parse_signer_digest('Signer #1 certificate SHA-256 digest: ABCD0123\n'),
            'abcd0123',
        )

    def test_parses_version_code_from_pubspec(self):
        self.assertEqual(version_code_from_pubspec('name: familyhelper\nversion: 1.0.1+2\n'), 2)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.dist = self.root / 'dist'
        self.dist.mkdir()
        self.candidates = {}
        self.metadata = {}
        for role in ('host', 'client'):
            old = self.dist / f'familyhelper-{role}.apk'
            new = self.root / f'app-{role}-release.apk'
            old.write_bytes(f'old-{role}'.encode())
            new.write_bytes(f'new-{role}'.encode())
            self.candidates[role] = new
            package = f'com.familyhelper.{role}'
            self.metadata[old] = ApkInfo(package, 1, 'old-signer')
            self.metadata[new] = ApkInfo(package, 2, 'old-signer')

    def inspect(self, path):
        return self.metadata[path]

    def test_rejects_same_version_before_replacing_either_apk(self):
        self.metadata[self.candidates['host']] = ApkInfo(
            'com.familyhelper.host', 1, 'old-signer'
        )
        with self.assertRaisesRegex(ValueError, 'versionCode'):
            publish_pair(self.candidates, self.dist, 1, self.inspect)
        self.assertEqual((self.dist / 'familyhelper-host.apk').read_bytes(), b'old-host')
        self.assertEqual((self.dist / 'familyhelper-client.apk').read_bytes(), b'old-client')

    def test_rejects_wrong_second_signer_without_partial_replacement(self):
        self.metadata[self.candidates['client']] = ApkInfo(
            'com.familyhelper.client', 2, 'new-signer'
        )
        with self.assertRaisesRegex(ValueError, 'signer'):
            publish_pair(self.candidates, self.dist, 2, self.inspect)
        self.assertEqual((self.dist / 'familyhelper-host.apk').read_bytes(), b'old-host')
        self.assertEqual((self.dist / 'familyhelper-client.apk').read_bytes(), b'old-client')

    def test_rejects_wrong_package_name(self):
        self.metadata[self.candidates['client']] = ApkInfo(
            'com.familyhelper.host', 2, 'old-signer'
        )
        with self.assertRaisesRegex(ValueError, 'package'):
            publish_pair(self.candidates, self.dist, 2, self.inspect)

    def test_preflight_rejects_version_not_greater_than_existing(self):
        with self.assertRaisesRegex(ValueError, 'versionCode'):
            check_existing_versions(self.dist, 1, self.inspect)

    def test_publishes_both_after_validation(self):
        publish_pair(self.candidates, self.dist, 2, self.inspect)
        self.assertEqual((self.dist / 'familyhelper-host.apk').read_bytes(), b'new-host')
        self.assertEqual((self.dist / 'familyhelper-client.apk').read_bytes(), b'new-client')

    def test_second_publish_failure_restores_first_existing_apk(self):
        real_replace = os.replace
        attempts = 0

        def fail_second_replace(source, destination):
            nonlocal attempts
            attempts += 1
            if attempts == 2:
                raise OSError('simulated disk failure')
            return real_replace(source, destination)

        with mock.patch('tool.release_guard.os.replace', side_effect=fail_second_replace):
            with self.assertRaisesRegex(OSError, 'simulated disk failure'):
                publish_pair(self.candidates, self.dist, 2, self.inspect)
        self.assertEqual((self.dist / 'familyhelper-host.apk').read_bytes(), b'old-host')
        self.assertEqual((self.dist / 'familyhelper-client.apk').read_bytes(), b'old-client')

    def test_next_run_recovers_interrupted_publish_before_version_check(self):
        pending = self.dist / '.release-transaction'
        pending.mkdir()
        (pending / 'backup-host.apk').write_bytes(b'old-host')
        (pending / 'backup-client.apk').write_bytes(b'old-client')
        (pending / 'prepared').write_text('ready')
        (self.dist / 'familyhelper-host.apk').write_bytes(b'new-host')

        recover_pending(self.dist)

        self.assertEqual((self.dist / 'familyhelper-host.apk').read_bytes(), b'old-host')
        self.assertEqual((self.dist / 'familyhelper-client.apk').read_bytes(), b'old-client')
        self.assertFalse(pending.exists())

    def test_failed_recovery_keeps_backup_for_retry(self):
        pending = self.dist / '.release-transaction'
        pending.mkdir()
        (pending / 'backup-host.apk').write_bytes(b'old-host')
        (pending / 'backup-client.apk').write_bytes(b'old-client')
        (pending / 'prepared').write_text('ready')
        (self.dist / 'familyhelper-host.apk').write_bytes(b'new-host')

        with mock.patch('tool.release_guard.shutil.copy2', side_effect=OSError('disk full')):
            with self.assertRaisesRegex(OSError, 'disk full'):
                recover_pending(self.dist)

        self.assertEqual((pending / 'backup-host.apk').read_bytes(), b'old-host')
        self.assertTrue(pending.exists())

    def test_build_script_refuses_same_version_before_flutter_runs(self):
        (self.root / 'pubspec.yaml').write_text('name: familyhelper\nversion: 1.0.0+1\n')
        calls = []
        with mock.patch('shutil.which', return_value=None):
            builder = importlib.import_module('tool.build_apks')
        with self.assertRaisesRegex(ValueError, 'versionCode'):
            builder.main(
                root=self.root,
                flutter='flutter-test',
                inspect=self.inspect,
                run_command=lambda args: calls.append(args),
            )
        self.assertEqual(calls, [])
        self.assertEqual((self.dist / 'familyhelper-host.apk').read_bytes(), b'old-host')
        self.assertEqual((self.dist / 'familyhelper-client.apk').read_bytes(), b'old-client')


if __name__ == '__main__':
    unittest.main()
