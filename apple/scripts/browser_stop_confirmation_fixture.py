#!/usr/bin/env python3
"""Compile frozen actual owners, then run controlled no-capture confirmation cases."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

root, output, core = map(lambda value: Path(value).resolve(), sys.argv[1:])
output.mkdir(parents=True, exist_ok=False)
source = output / 'source'
source.mkdir()
sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
compiled = [
    'StreamMac/BrowserCaptureExclusions.swift', 'StreamMac/BrowserWidgetAudioProtocol.swift',
    'StreamMac/BrowserWidgetLocalContent.swift', 'StreamMac/BrowserWidgetVisualProtocol.swift',
    'StreamMac/BrowserWidgetAudioSocket.swift', 'StreamMac/BrowserWidgetAudioCapture.swift',
    'StreamMac/BrowserWidgetHelperSession.swift', 'StreamMac/AudioMixEngine.swift',
    'StreamMac/GuestMediaReceipts.swift', 'StreamMac/IsolatedRecordingTypes.swift',
    'StreamMac/IsolatedVideoTypes.swift', 'StreamMac/RecordingChatPaint.swift',
    'StreamMac/RecordingChatTypes.swift', 'StreamMac/RecordingChatArchive.swift',
    'StreamMac/RecordingChatReader.swift', 'StreamMac/RecordingPreferences.swift',
    'StreamMac/RawVideoResourceCoordinator.swift', 'StreamMac/FrameDeliveryBroker.swift',
    'StreamMac/FrameDeliveryConverter.swift', 'StreamMac/RecordingFrameDelivery.swift',
    'StreamMac/ProgramRecordingSession.swift',
]
fixtures = ['scripts/browser_capture_authority_harness.swift',
            'scripts/browser_helper_lifecycle_checks.swift',
            'scripts/browser_stop_confirmation_session_harness.swift']
context = ['StreamMac/LayerGraph.swift', 'StreamMac/CaptureSourcePool.swift',
           'StreamMac/BrowserOverlayHost.swift']
for name in compiled + fixtures + context:
    destination = source / name
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(root / name, destination)

slices = {}
def declaration(path, name):
    text = (source / path).read_text()
    matches = list(re.finditer(r'(?ms)^(?:struct|enum) ' + re.escape(name) + r'\b[^\n]*\{.*?^}', text))
    if len(matches) != 1:
        raise SystemExit('Production declaration changed: ' + name)
    result = matches[0].group(0)
    slices[path + ':' + name] = hashlib.sha256(result.encode()).hexdigest()
    return result

graph = 'StreamMac/LayerGraph.swift'
names = ['GraphID', 'CameraSourcePayload', 'ScreenSourcePayload', 'CaptureRegion',
         'ScreenZoomOptions', 'ActiveAppTrackingOptions', 'CapturePrivacyOptions',
         'EffectiveCapturePrivacy', 'WebSourcePayload', 'SyphonSourcePayload', 'AppAudioSourcePayload']
identities = 'import Foundation\nimport StreamCore\n' + '\n'.join(declaration(graph, name) for name in names)
for pattern in [r'^enum SourceDefinitionTag \{\}$', r'^typealias SourceDefinitionID = .+$']:
    matches = re.findall(pattern, (source / graph).read_text(), re.M)
    if len(matches) != 1:
        raise SystemExit('Production identity alias changed')
    identities += '\n' + matches[0] + '\n'
privacy = re.findall(r'(?ms)^extension ScreenSourcePayload \{\n    /// Resolves.*?^}', (source / graph).read_text())
if len(privacy) != 1:
    raise SystemExit('Production privacy extension changed')
identities += '\n' + privacy[0] + '\n'
identities += declaration('StreamMac/CaptureSourcePool.swift', 'CaptureSourceKey') + '\n'
identities += declaration('StreamMac/BrowserOverlayHost.swift', 'BrowserOverlayLoadState') + '\n'
(source / 'ProductionIdentities.swift').write_text(identities)
frameworks = output / 'frameworks'
frameworks.mkdir()
shutil.copytree(core, frameworks / 'StreamCore.framework')
results = {}
source_hashes = {name: sha(source / name) for name in compiled + fixtures + context}

# Variants copy only the actual capture/session whose one policy is reverted.
variants = ['positive-capture', 'positive-session', 'false-confirmation-capture',
            'false-confirmation-session', 'old-close-order-session']
for variant in variants:
    variant_dir = output / variant
    variant_dir.mkdir()
    inputs = [source / 'ProductionIdentities.swift'] + [source / name for name in compiled]
    capture = source / 'StreamMac/BrowserWidgetAudioCapture.swift'
    session = source / 'StreamMac/BrowserWidgetHelperSession.swift'
    if variant == 'false-confirmation-capture':
        text = capture.read_text()
        anchor = '            if stopped == .confirmed {\n'
        assert text.count(anchor) == 1
        text = text.replace(anchor, '            stopped = .confirmed // Counterfactual: discard native stop outcome.\n' + anchor)
        capture = variant_dir / capture.name
        capture.write_text(text)
    if variant == 'false-confirmation-session':
        text = session.read_text()
        anchor = '        guard stopped == .confirmed else {\n'
        assert text.count(anchor) == 1
        session = variant_dir / session.name
        session.write_text(text.replace(anchor, '        if false { // Counterfactual: ignore unconfirmed capture retirement.\n'))
    if variant == 'old-close-order-session':
        text = session.read_text()
        close = '''        let retiringConnection = resources.connection
        try? retiringConnection?.send(.init(action: .close)); retiringConnection?.close()
        if let retiringConnection, connection === retiringConnection { connection = nil }
        BrowserWidgetLocalRetirement.retain(resources.pages, until: { retiringConnection == nil || retiringConnection?.hasTerminated == true })
'''
        anchor = '        audioTask?.cancel(); await audioTask?.value; audioTask = nil\n'
        assert text.count(close) == 1 and text.count(anchor) == 1
        text = text.replace(close, '').replace(anchor, close + anchor)
        session = variant_dir / session.name
        session.write_text(text)
    inputs = [capture if path.name == capture.name else session if path.name == session.name else path for path in inputs]
    if variant.endswith('capture'):
        inputs.append(source / 'scripts/browser_capture_authority_harness.swift')
    else:
        inputs += [source / 'scripts/browser_helper_lifecycle_checks.swift', source / 'scripts/browser_stop_confirmation_session_harness.swift']
    command = ['swiftc', '-swift-version', '6', '-j2', '-strict-concurrency=complete',
               '-parse-as-library', '-DSTREAM_NATIVE_VALIDATION', '-module-cache-path', str(output / 'module-cache'),
               '-F', str(frameworks), '-framework', 'StreamCore'] + list(map(str, inputs)) + ['-o', str(variant_dir / 'harness')]
    (variant_dir / 'compile-command.json').write_text(json.dumps(command, indent=2) + '\n')
    with (variant_dir / 'compile.log').open('wb') as log:
        completed = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
    result = {'compileExit': completed.returncode}
    results[variant] = result
    if completed.returncode == 0:
        env = dict(os.environ, DYLD_FRAMEWORK_PATH=str(frameworks), SWIFT_BACKTRACE='enable=no')
        args = [str(variant_dir / 'harness')]
        if variant == 'false-confirmation-capture':
            args.append('unconfirmed-stop')
        with (variant_dir / 'runtime.log').open('wb') as log:
            try:
                completed = subprocess.run(args, stdout=log, stderr=subprocess.STDOUT, timeout=45, env=env)
                result['runtimeExit'] = completed.returncode
            except subprocess.TimeoutExpired:
                result['runtimeTimeoutSeconds'] = 45
    (output / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
    print(variant, json.dumps(result), flush=True)
    positive = variant.startswith('positive')
    if result.get('compileExit') != 0 or 'runtimeTimeoutSeconds' in result or (positive and result.get('runtimeExit') != 0):
        break
    if not positive and result.get('runtimeExit') == 0:
        break

receipt = {'scope': 'Controlled actual Capture/Session and real mixer construction/registry/holdback only; no mixer.run, devices, SCK, helper, WebKit, IPC, output or network.',
           'compiledSources': source_hashes, 'identitySlices': slices,
           'generatedIdentitiesSHA256': sha(source / 'ProductionIdentities.swift'),
           'frameworkSHA256': sha(frameworks / 'StreamCore.framework/StreamCore'),
           'results': results, 'runtimeDeadlineSeconds': 45,
           'retryBound': 'One attempt per admitted old run/owner; production opaque await has no wall-clock deadline.',
           'artifacts': {str(path): sha(path) for path in output.rglob('*') if path.is_file()}}
(output / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
passed = len(results) == len(variants) and all(result.get('compileExit') == 0 and
    (result.get('runtimeExit') == 0 if name.startswith('positive') else result.get('runtimeExit', 0) != 0)
    and 'runtimeTimeoutSeconds' not in result for name, result in results.items())
raise SystemExit(0 if passed else 1)
