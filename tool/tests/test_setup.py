# Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import setup  # noqa: E402


class StateTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        d = Path(self.tmp.name)
        self.patches = [
            mock.patch.object(setup, 'STATE_DIR', d),
            mock.patch.object(setup, 'STATE_FILE', d / 'state.json'),
        ]
        for p in self.patches:
            p.start()

    def tearDown(self):
        for p in self.patches:
            p.stop()
        self.tmp.cleanup()

    def run_main(self, argv, steps):
        with mock.patch.object(sys, 'argv', ['setup.py', *argv]), \
             mock.patch.object(setup, 'STEPS', steps), \
             mock.patch.object(setup, 'finish'):
            return setup.main()

    def test_resume_skips_completed_steps_but_always_rechecks_environment(self):
        calls = []
        steps = [(f's{i}', (lambda i: lambda st: calls.append(i))(i)) for i in range(1, 4)]
        setup.save_state({'done': [1, 2]})
        self.assertEqual(self.run_main([], steps), 0)
        self.assertEqual(calls, [1, 3])
        self.assertEqual(setup.load_state()['done'], [1, 2, 3])

    def test_from_reruns_later_steps(self):
        calls = []
        steps = [(f's{i}', (lambda i: lambda st: calls.append(i))(i)) for i in range(1, 4)]
        setup.save_state({'done': [1, 2, 3]})
        self.assertEqual(self.run_main(['--from', '2'], steps), 0)
        self.assertEqual(calls, [1, 2, 3])

    def test_failure_saves_progress_and_stops(self):
        calls = []

        def boom(st):
            st['project'] = 'demo-project'
            raise setup.SetupError('壞了', ['detail'])

        steps = [('a', lambda st: calls.append(1)), ('b', boom), ('c', lambda st: calls.append(3))]
        self.assertEqual(self.run_main([], steps), 1)
        self.assertEqual(calls, [1])
        state = setup.load_state()
        self.assertEqual(state['done'], [1])
        self.assertEqual(state['project'], 'demo-project')

    def test_state_file_never_contains_generated_secrets(self):
        state = {'done': [], 'project': 'demo-project'}
        sent = []
        with mock.patch.object(setup, 'firebase', side_effect=lambda args, pid=None, **kw: sent.append((args, kw)) or mock.Mock(returncode=1)), \
             mock.patch.object(setup, 'FUNCTIONS', Path(self.tmp.name)), \
             mock.patch.object(setup, 'BACKEND', Path(self.tmp.name)), \
             mock.patch.object(setup, 'confirm', return_value=False):
            state['databaseUrl'] = 'https://demo-project-default-rtdb.asia-southeast1.firebasedatabase.app'
            setup.step_backend(state)
        secret_sets = [(a, kw) for a, kw in sent if a[0] == 'functions:secrets:set']
        self.assertEqual([a[1] for a, _ in secret_sets],
                         ['PAIR_PEPPER', 'TURN_SECRET', 'CLOUDFLARE_TURN_KEY_ID', 'CLOUDFLARE_TURN_API_TOKEN'])
        for args, kw in secret_sets:
            # Values travel on stdin only, never as command-line arguments.
            self.assertIn('--data-file=-', args)
            self.assertTrue(kw['stdin'].strip())
            self.assertNotIn(kw['stdin'].strip(), ' '.join(args))
        pepper = secret_sets[0][1]['stdin'].strip()
        self.assertGreaterEqual(len(pepper), 48)
        self.assertEqual(secret_sets[2][1]['stdin'].strip(), 'disabled')
        setup.save_state(state)
        self.assertNotIn(pepper, (Path(self.tmp.name) / 'state.json').read_text())
        rc = json.loads((Path(self.tmp.name) / '.firebaserc').read_text())
        self.assertEqual(rc['projects']['default'], 'demo-project')


class AppLookupTest(unittest.TestCase):
    def test_reuses_existing_app_with_matching_package(self):
        listed = {'result': [{'packageName': 'com.other', 'appId': 'x'},
                             {'packageName': 'com.familyhelper.host', 'appId': '1:2:android:abc'}]}
        with mock.patch.object(setup, 'firebase_json', return_value=listed) as fj:
            self.assertEqual(setup._find_or_create_app('demo', 'host'), '1:2:android:abc')
        self.assertEqual(fj.call_count, 1, 'must not create a duplicate app')

    def test_creates_app_when_missing(self):
        responses = [{'result': []}, {'result': {'appId': 'new-id'}}]
        with mock.patch.object(setup, 'firebase_json', side_effect=responses) as fj:
            self.assertEqual(setup._find_or_create_app('demo', 'client'), 'new-id')
        create_args = fj.call_args_list[1].args[0]
        self.assertIn('com.familyhelper.client', create_args)


class ValidationTest(unittest.TestCase):
    def test_project_id_rules(self):
        for good in ('familyhelper-chen', 'fh2026', 'a-b-c-d-e'):
            self.assertRegex(good, setup.PROJECT_ID)
        for bad in ('FamilyHelper', '1family', 'abc', 'family_helper', 'family-', 'a' * 31):
            self.assertIsNone(setup.PROJECT_ID.match(bad), bad)


class CommandPathTest(unittest.TestCase):
    def test_firebase_uses_resolved_windows_command(self):
        with mock.patch.object(setup.shutil, 'which', return_value=r'C:\Tools\firebase.cmd'):
            self.assertEqual(setup.firebase_cmd()[0], r'C:\Tools\firebase.cmd')

    def test_npx_fallback_uses_resolved_windows_command(self):
        paths = {'firebase': None, 'npx': r'C:\Tools\npx.cmd'}
        with mock.patch.object(setup.shutil, 'which', side_effect=paths.get):
            self.assertEqual(setup.firebase_cmd()[0], r'C:\Tools\npx.cmd')

    def test_deploy_uses_resolved_npm_command(self):
        with mock.patch.object(setup.shutil, 'which', return_value=r'C:\Tools\npm.cmd'), \
             mock.patch.object(setup, 'run') as run, \
             mock.patch.object(setup, 'firebase'):
            setup.step_deploy({'project': 'demo-project', 'storageBucket': ''})
        self.assertEqual(run.call_args.args[0][0], r'C:\Tools\npm.cmd')

    def test_version_check_uses_resolved_command(self):
        with mock.patch.object(setup.shutil, 'which', return_value=r'C:\Tools\flutter.cmd'), \
             mock.patch.object(setup.subprocess, 'run', return_value=mock.Mock(stdout='ok', stderr='')) as run:
            self.assertEqual(setup.version_of(['flutter', '--version']), 'ok')
        self.assertEqual(run.call_args.args[0][0], r'C:\Tools\flutter.cmd')


if __name__ == '__main__':
    unittest.main()
