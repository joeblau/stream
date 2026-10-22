"""No browser, WebRTC, GPU or device: actual launcher + owned fake process."""
import json
import os
import pathlib
import signal
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

import owned_loopback_process as processes
import run_owned_null_loopback as wrapper

NODE = os.environ.get('STREAM_TEST_NODE', '/tmp/stream-native-integration-tools-20261021/node_modules/node/bin/node')


class OwnedLoopbackTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='stream-owned-wrapper-test-')
        self.root = pathlib.Path(self.directory.name)
        real = self.root / 'real temporary root with spaces'
        real.mkdir(mode=0o700)
        alias = self.root / 'temporary-alias'
        alias.symlink_to(real, target_is_directory=True)
        self.fake = self.root / 'fake-owned-output'
        self.pids = self.root / 'fake-pids.json'
        self.fake.write_text('''#!/usr/bin/env python3
import json,os,signal,subprocess,sys,time
signal.signal(signal.SIGTERM,signal.SIG_IGN)
child=subprocess.Popen([sys.executable,'-c','import signal,time;signal.signal(signal.SIGTERM,signal.SIG_IGN);time.sleep(60)'])
open(os.environ['STREAM_FAKE_PIDS'],'w').write(json.dumps([os.getpid(),child.pid]))
while True:time.sleep(.05)
''')
        self.fake.chmod(0o700)
        self.environment = dict(CHROME_BIN=str(self.fake), TMPDIR=str(alias), STREAM_FAKE_PIDS=str(self.pids))

    def tearDown(self):
        # A failing test also retires only its own already captured identities.
        for value in getattr(self, 'captured', []):
            if processes.matches(value, processes.identity(value['pid'])):
                os.kill(value['pid'], signal.SIGKILL)
        self.directory.cleanup()

    def artifacts(self, name):
        target = self.root / name
        target.mkdir(mode=0o700)
        return target

    def assert_drained(self, artifacts):
        receipt = json.loads((artifacts / 'receipt.json').read_text())
        self.assertEqual(receipt['result'], 'UNQUALIFIED')
        self.assertEqual(receipt['reason'], 'owned-signal-SIGTERM')
        self.assertEqual(receipt['failureSnapshot']['reason'], 'owned-abort')
        self.assertIn(receipt['processRetirement'], ('drained', 'absent'))
        self.assertTrue(self.pids.exists())
        pids = json.loads(self.pids.read_text())
        self.assertTrue(all(processes.identity(pid) is None for pid in pids), 'Owned fake group was not drained')
        manifest = json.loads((artifacts / 'owned-process.json').read_text())
        self.assertEqual(pathlib.Path(manifest['ownedDirectory']).parent, (self.root / 'real temporary root with spaces').resolve())
        self.assertFalse(pathlib.Path(manifest['ownedDirectory']).exists(), 'Launcher did not remove its exact owned directory')

    def test_monitor_assertion_after_exact_canonical_profile_validation_cleans_up(self):
        artifacts = self.artifacts('assertion')

        def refuse(path, node_pid, owned, owned_identity):
            expected = wrapper.validate_manifest(path, node_pid, owned, owned_identity)
            deadline = time.monotonic() + 2
            while not self.pids.exists() and time.monotonic() < deadline:
                time.sleep(.01)
            self.assertTrue(self.pids.exists(), 'Owned fake never initialized')
            self.captured = [expected] + processes.group_members(expected)
            raise AssertionError('Deliberate owned monitor failure')

        proof = wrapper.run(NODE, artifacts, inspect=refuse, environment=self.environment)
        self.assertEqual(proof['result'], 'UNQUALIFIED')
        self.assertEqual(proof['monitorFailure'], 'AssertionError')
        self.assertFalse(proof['remainingOwnedBrowser'])
        self.assert_drained(artifacts)

    def test_owned_wrapper_deadline_cleans_up_without_extending_media_gates(self):
        artifacts = self.artifacts('deadline')
        proof = wrapper.run(NODE, artifacts, deadline=1, environment=self.environment)
        self.assertTrue(proof['browserArgumentsVerified'])
        self.assertEqual(proof['exitCode'], 77)
        self.assertFalse(proof['remainingOwnedBrowser'])
        self.assert_drained(artifacts)

    def test_wrapper_signal_terminalizes_real_launcher_and_drains_detached_fake_group(self):
        artifacts = self.artifacts('signal')
        env = os.environ.copy()
        env.update(self.environment)
        with (self.root / 'signal-test.log').open('w') as output:
            process = subprocess.Popen(['python3', str(pathlib.Path(wrapper.__file__)), '--node', NODE,
                '--artifacts', str(artifacts)], env=env, stdout=output, stderr=subprocess.STDOUT)
            try:
                deadline = time.monotonic() + 5
                while not (artifacts / 'owned-process.json').exists() and time.monotonic() < deadline:
                    time.sleep(.025)
                self.assertTrue((artifacts / 'owned-process.json').exists())
                expected = wrapper.read_manifest(artifacts / 'owned-process.json')['chrome']
                self.captured = [expected] + processes.group_members(expected)
                # Let the wrapper consume the atomic manifest before signal.
                time.sleep(.1)
                process.send_signal(signal.SIGTERM)
                self.assertEqual(process.wait(timeout=10), 77)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=2)
        self.assert_drained(artifacts)

    def test_reused_pid_or_process_group_is_never_signaled(self):
        expected = dict(pid=123456, ppid=1, pgid=123456, uid=os.getuid(), birth=[100, 1])
        sent = []
        current = dict(expected, birth=[101, 1])
        result = processes.retire(expected, snapshot=lambda _: current, send=lambda *args: sent.append(args))
        self.assertEqual(result, 'replaced')
        self.assertEqual(sent, [])

    def test_surviving_original_member_pins_group_after_leader_exits(self):
        leader = dict(pid=123456, ppid=1, pgid=123456, uid=os.getuid(), birth=[100, 1])
        child = dict(leader, pid=123457, ppid=123456, birth=[100, 2])
        live = {leader['pid']: leader, child['pid']: child}
        sent, ticks = [], [0]

        def send(group, operation):
            sent.append((group, operation))
            live.pop(leader['pid'], None)
            if operation == signal.SIGKILL:
                live.clear()

        def clock():
            ticks[0] += .5
            return ticks[0]

        result = processes.retire(leader, snapshot=live.get, send=send, sleep=lambda _: None,
            clock=clock, members=lambda _: [child])
        self.assertEqual(result, 'drained')
        self.assertEqual(sent, [(123456, signal.SIGTERM), (123456, signal.SIGKILL)])

    def test_group_membership_read_cannot_adopt_a_replacement_leader(self):
        original = dict(pid=123456, ppid=1, pgid=123456, uid=os.getuid(), birth=[100, 1])
        current, sent = [original], []

        def members(_expected):
            current[0] = dict(original, birth=[101, 1])
            return [current[0]]

        result = processes.retire(original, snapshot=lambda _: current[0], members=members,
                                 send=lambda *args: sent.append(args))
        self.assertEqual(result, 'replaced')
        self.assertEqual(sent, [])

    def test_private_manifest_is_atomic_bounded_and_never_replaces_evidence(self):
        target = self.root / 'manifest.json'
        processes.atomic_private_json(target, {'owned': True})
        self.assertEqual(target.stat().st_mode & 0o777, 0o600)
        before = target.read_bytes()
        with self.assertRaises(FileExistsError):
            processes.atomic_private_json(target, {'replacement': True})
        self.assertEqual(target.read_bytes(), before)
        with self.assertRaises(RuntimeError):
            processes.atomic_private_json(self.root / 'oversized.json', {'unsafe': 'x' * 5000})

    def test_replaced_directory_incarnation_is_rejected_before_process_authority(self):
        owned = self.root / 'owned'
        owned.mkdir(mode=0o700)
        (owned / 'profile').mkdir(mode=0o700)
        info = owned.stat()
        original = dict(device=str(info.st_dev), inode=str(info.st_ino))
        target = self.root / 'manifest.json'
        processes.atomic_private_json(target, dict(nodePID=123, ownedDirectory=str(owned), ownedIdentity=original,
                                                   profile=str(owned / 'profile'), chrome={}))
        owned.rename(self.root / 'retired-owned')
        owned.mkdir(mode=0o700)
        with self.assertRaisesRegex(RuntimeError, 'incarnation changed'):
            wrapper.validate_manifest(target, 123, owned, original)

    def test_exact_profile_and_permission_flags_are_checked_on_captured_child(self):
        owned = self.root / 'owned flags'
        owned.mkdir(mode=0o700)
        (owned / 'profile').mkdir(mode=0o700)
        info = owned.stat()
        directory_identity = dict(device=str(info.st_dev), inode=str(info.st_ino))
        child = dict(pid=123456, ppid=123, pgid=123456, uid=os.getuid(), birth=[1, 2])
        target = self.root / 'manifest.json'
        processes.atomic_private_json(target, dict(nodePID=123, ownedDirectory=str(owned), ownedIdentity=directory_identity,
                                                   profile=str(owned / 'profile'), chrome=child))
        prefix = 'owned-executable --disable-audio-output --user-data-dir=' + str(owned.resolve() / 'profile')
        with patch.object(wrapper, 'capture', return_value=child):
            for command, reason in [(prefix + '-other about:blank', 'exact owned profile'),
                    (prefix + ' --use-fake-ui-for-media-stream=true about:blank', 'arguments refused')]:
                with patch.object(wrapper.subprocess, 'check_output', return_value=command):
                    with self.assertRaisesRegex(RuntimeError, reason):
                        wrapper.validate_manifest(target, 123, owned, directory_identity)


if __name__ == '__main__':
    unittest.main(verbosity=2)
