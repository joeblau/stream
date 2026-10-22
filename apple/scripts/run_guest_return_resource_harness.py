#!/usr/bin/env python3
"""Owned BGRA/VT resource proof. No peer, RTC transport, capture or device graph."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--core-products', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--resource-source', type=Path)
parser.add_argument('--broker-source', type=Path)
parser.add_argument('--converter-source', type=Path)
parser.add_argument('--paint-source', type=Path)
args = parser.parse_args()
apple = Path(__file__).resolve().parents[1]
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=False)
snapshot = output / 'sources'
snapshot.mkdir()
bindings = []

def copy(source, name=None):
    source = source.resolve()
    destination = snapshot / (name or source.name)
    data = source.read_bytes()
    destination.write_bytes(data)
    bindings.append({'path': str(source), 'snapshot': str(destination), 'bytes': len(data),
                     'sha256': hashlib.sha256(data).hexdigest()})
    return destination

def declaration(path, marker):
    source = path.read_text()
    assert source.count(marker) == 1, marker
    begin = source.index(marker)
    opening = source.index('{', begin)
    depth = 1
    end = opening + 1
    while depth:
        assert end < len(source), marker
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[begin:end]

def run(label, command, timeout):
    log = output / (label + '.log')
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               start_new_session=True, text=True)
    try:
        text, _ = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            text, _ = process.communicate(timeout=3)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            text, _ = process.communicate()
        log.write_text(text)
        raise RuntimeError(f'{label} exceeded its owned {timeout}s deadline; no retry')
    log.write_text(text)
    print(text, end='', flush=True)
    manifest['checks'].append({'label': label, 'command': command, 'exit': process.returncode,
                              'log': str(log), 'sha256': hashlib.sha256(log.read_bytes()).hexdigest()})
    save()
    if process.returncode:
        raise SystemExit(process.returncode)

paths = [apple / 'StreamMac' / name for name in (
    'GuestReturnVideoResources.swift', 'GuestReturnFrameDelivery.swift',
    'NativeGuestReturnVideoEncoder.swift', 'NativeGuestReturnVideoBudget.swift')]
paths += [args.resource_source or apple / 'StreamMac/RawVideoResourceCoordinator.swift',
          args.broker_source or apple / 'StreamMac/FrameDeliveryBroker.swift',
          args.converter_source or apple / 'StreamMac/FrameDeliveryConverter.swift',
          args.paint_source or apple / 'StreamMac/RecordingChatPaint.swift',
          apple / 'scripts/guest_return_resource_harness.swift']
swift = [str(copy(path)) for path in paths]
receipts = copy(apple / 'StreamMac/GuestMediaReceipts.swift', 'GuestMediaReceipts.original')
sink = copy(apple / 'StreamMac/NativeGuestMediaSink.swift', 'NativeGuestMediaSink.original')
audio = copy(apple / 'StreamMac/NativeGuestReturnAudioEncoder.swift', 'NativeGuestReturnAudioEncoder.original')
types = snapshot / 'ActualDeclarations.swift'
types.write_text('import CoreMedia\nimport Foundation\n' + '\n'.join([
    declaration(receipts, 'struct GuestReceiveLease:'), declaration(sink, 'struct GuestReturnVideoFrame:'),
    declaration(audio, 'enum NativeGuestReturnAudioError:'), declaration(audio, 'enum NativeGuestReturnClock {')]) + '\n')
swift.append(str(types))
bridge = copy(apple / 'NativeGuestReceivePrototype/GuestReceive.cpp', 'GuestReceive.original')
header = copy(apple / 'NativeGuestReceivePrototype/GuestReceive.h')
copy(apple / 'NativeGuestReceivePrototype/GuestReturnH264.hpp')
packetizer = snapshot / 'ActualPacketCost.cpp'
packetizer.write_text('#include "GuestReceive.h"\n#include "GuestReturnH264.hpp"\n' +
    declaration(bridge, 'extern "C" uint32_t SGReturnH264SendBytes(') + '\n')
products = args.core_products.resolve()
framework = products / 'StreamCore.framework'
assert framework.is_dir()
core = output / 'frameworks'
core.mkdir()
shutil.copytree(framework, core / framework.name, symlinks=True)
manifest = {'scope': __doc__, 'bindings': bindings, 'checks': [],
            'coreBinarySHA256': hashlib.sha256((core / 'StreamCore.framework/Versions/A/StreamCore').read_bytes()).hexdigest(),
            'generated': {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in (types, packetizer)}}

def save():
    (output / 'receipt.json').write_text(json.dumps(manifest, indent=2) + '\n')

save()
run('packetizer-build', ['xcrun', 'clang++', '-std=c++17', '-c', str(packetizer), '-o', str(output / 'PacketCost.o')], 60)
binary = output / 'GuestReturnResourceHarness'
run('swift-build', ['xcrun', 'swiftc', '-j2', '-swift-version', '6', '-strict-concurrency=complete',
    '-DSTREAM_NATIVE_VALIDATION', '-DSTREAM_GUEST_VALIDATION', '-parse-as-library',
    '-F', str(core), '-framework', 'StreamCore', '-import-objc-header', str(header),
    '-Xlinker', '-rpath', '-Xlinker', str(core)] + swift + [str(output / 'PacketCost.o'), '-Xlinker', '-lc++', '-o', str(binary)], 180)
manifest['binarySHA256'] = hashlib.sha256(binary.read_bytes()).hexdigest()
save()
run('runtime', [str(binary)], 45)
