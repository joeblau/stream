"""One explicitly scheduled diagnostic. Never retries or changes media flags."""
import argparse
import json
import os
import pathlib
import signal
import stat
import subprocess
import tempfile
import time

from owned_loopback_process import atomic_private_json, capture, identity, matches, retire


def read_manifest(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor, 'rb') as source:
        info = os.fstat(source.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077 or info.st_size > 4096:
            raise RuntimeError('Refused nonprivate or oversized process manifest')
        value = json.loads(source.read(4097))
    return value


def validate_manifest(path, node_pid, owned, owned_identity):
    value = read_manifest(path)
    owned = pathlib.Path(owned).resolve(strict=True)
    info = owned.stat()
    if dict(device=str(info.st_dev), inode=str(info.st_ino)) != owned_identity or value['ownedIdentity'] != owned_identity:
        raise RuntimeError('Owned directory incarnation changed')
    if value['nodePID'] != node_pid or pathlib.Path(value['ownedDirectory']).resolve(strict=True) != owned:
        raise RuntimeError('Manifest does not belong to the current owned Node/directory')
    expected_profile = owned / 'profile'
    if pathlib.Path(value['profile']).resolve(strict=True) != expected_profile:
        raise RuntimeError('Manifest profile differs from the exact fresh owned profile')
    expected = value['chrome']
    current = capture(expected['pid'], node_pid)
    if not matches(expected, current):
        raise RuntimeError('Browser incarnation changed before ownership validation')
    command = subprocess.check_output(['ps', '-p', str(expected['pid']), '-o', 'command='], text=True, timeout=1).strip()
    # ps does not quote spaces: compare the complete known token plus its
    # following separator, never split a profile path or accept a prefix.
    profile_token = '--user-data-dir=' + str(expected_profile)
    if ' ' + profile_token + ' ' not in command and not command.endswith(' ' + profile_token):
        raise RuntimeError('Browser argv differs from the exact owned profile')
    tokens = command.split()
    forbidden = {'--use-fake-device-for-media-stream', '--use-fake-ui-for-media-stream',
                 '--auto-select-desktop-capture-source', '--enable-usermedia-screen-capturing'}
    if '--disable-audio-output' not in tokens or any(token.split('=', 1)[0] in forbidden for token in tokens):
        raise RuntimeError('Owned null-output arguments refused')
    return expected


def run(node, artifacts, *, deadline=100, inspect=validate_manifest, environment=None):
    artifacts = pathlib.Path(artifacts).resolve(strict=True)
    if any(artifacts.iterdir()) or artifacts.stat().st_mode & 0o077:
        raise RuntimeError('Use a fresh private artifact directory; never overwrite old receipts')
    env = os.environ.copy()
    if environment:
        env.update(environment)
    metadata = json.loads(subprocess.check_output([node, '--input-type=module', '-e',
        "import os from 'node:os';import fs from 'node:fs';console.log(JSON.stringify({version:process.versions.node,root:fs.realpathSync(os.tmpdir())}))"], text=True, timeout=5, env=env))
    major, minor, *_ = map(int, metadata['version'].split('.'))
    if major != 24 or minor < 15:
        raise RuntimeError('Node >=24.15 <25 required')
    temporary_root = pathlib.Path(metadata['root']).resolve(strict=True)
    owned = pathlib.Path(tempfile.mkdtemp(prefix='stream-owned-null-loopback-', dir=temporary_root)).resolve(strict=True)
    os.chmod(owned, 0o700)
    info = owned.stat()
    owned_identity = dict(device=str(info.st_dev), inode=str(info.st_ino))
    manifest = artifacts / 'owned-process.json'
    receipt = artifacts / 'receipt.json'
    env.update(STREAM_LOOPBACK_RECEIPT=str(receipt), STREAM_LOOPBACK_OWNED_DIRECTORY=str(owned),
               STREAM_LOOPBACK_PROCESS_MANIFEST=str(manifest), STREAM_LOOPBACK_OWNED_IDENTITY=json.dumps(owned_identity),
               STREAM_LOOPBACK_MONITOR_READY=str(artifacts / 'monitor-ready.json'))
    script = pathlib.Path(__file__).with_name('owned-null-audio-loopback.mjs')
    process = None
    node_identity = None
    browser = None
    failure = None
    prior_handlers = {}
    started = time.monotonic()
    proof = dict(attemptCount=1, nodeVersion=metadata['version'], browserArgumentsVerified=False)

    def interrupted(signum, _frame):
        raise RuntimeError('Owned wrapper signal ' + signal.Signals(signum).name)

    try:
        for operation in (signal.SIGINT, signal.SIGTERM):
            prior_handlers[operation] = signal.signal(operation, interrupted)
        with (artifacts / 'attempt.log').open('x') as output:
            process = subprocess.Popen([node, str(script), '--fake-audio-output'], cwd=script.parents[4],
                env=env, stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
            node_identity = capture(process.pid, os.getpid())
            while process.poll() is None:
                if manifest.exists() and browser is None:
                    # Capture cleanup authority FIRST; any subsequent monitor
                    # refusal must still retire this actual owned child.
                    candidate = read_manifest(manifest)['chrome']
                    browser = capture(candidate['pid'], process.pid)
                    browser = inspect(manifest, process.pid, owned, owned_identity)
                    proof['browserArgumentsVerified'] = True
                    atomic_private_json(artifacts / 'monitor-ready.json', dict(nodePID=process.pid,
                        chrome=browser, ownedIdentity=owned_identity))
                if time.monotonic() - started > deadline:
                    raise RuntimeError('External owned attempt deadline exceeded')
                time.sleep(.025)
            proof['exitCode'] = process.returncode
    except BaseException as error:
        failure = type(error).__name__
        proof['monitorFailure'] = failure
        proof['exitCode'] = 77
    finally:
        for operation in prior_handlers:
            signal.signal(operation, signal.SIG_IGN)
        # An assertion/deadline/signal cannot escape cleanup. Give the exact
        # still-owned Node child a bounded opportunity to write UNQUALIFIED.
        if process is not None and process.poll() is None:
            if browser is None and node_identity and matches(node_identity, identity(process.pid)):
                # Covers abort/refusal before manifest publication. Only a
                # captured direct child leading its own new group qualifies.
                try:
                    children = subprocess.run(['pgrep', '-P', str(process.pid)], capture_output=True, text=True, timeout=1)
                    for child in children.stdout.split():
                        try:
                            browser = capture(int(child), process.pid)
                            break
                        except RuntimeError:
                            continue
                except (OSError, subprocess.TimeoutExpired):
                    proof['preManifestCapture'] = 'unavailable'
            # Without a captured identity this is still the unreaped Popen
            # child; its PID cannot have been reused before wait/poll reaps it.
            if node_identity is None or matches(node_identity, identity(process.pid)):
                process.send_signal(signal.SIGTERM)
            try:
                process.wait(timeout=8)
            except subprocess.TimeoutExpired:
                if node_identity is None or matches(node_identity, identity(process.pid)):
                    process.kill()
                try:
                    process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    proof['nodeRetirement'] = 'unconfirmed'
                    failure = failure or 'OwnedNodeCleanupUnconfirmed'
                    proof['exitCode'] = 77
        if browser is not None:
            try:
                proof['browserRetirement'] = retire(browser)
            except (OSError, RuntimeError, subprocess.TimeoutExpired):
                proof['browserRetirement'] = 'unconfirmed'
            proof['remainingOwnedBrowser'] = matches(browser, identity(browser['pid']))
            if proof['remainingOwnedBrowser'] or proof['browserRetirement'] not in ('absent', 'drained'):
                failure = failure or 'OwnedCleanupUnconfirmed'
                proof['exitCode'] = 77
        else:
            proof['remainingOwnedBrowser'] = None
        for operation, handler in prior_handlers.items():
            signal.signal(operation, handler)
        proof['elapsedSeconds'] = round(time.monotonic() - started, 3)
        proof['result'] = 'UNQUALIFIED' if failure or proof.get('exitCode') != 0 or proof['remainingOwnedBrowser'] is not False else 'DIAGNOSTIC_COMPLETE'
        atomic_private_json(artifacts / 'process-proof.json', proof)
    return proof


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--node', required=True)
    parser.add_argument('--artifacts', required=True)
    args = parser.parse_args()
    outcome = run(args.node, args.artifacts)
    print(json.dumps(outcome, indent=2), flush=True)
    raise SystemExit(outcome['exitCode'])
