#!/usr/bin/env python3
"""Read-only audit of retained broker controls, native results and source bindings."""
import argparse
import hashlib
import json
import pathlib
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('receipt', nargs='?', type=pathlib.Path)
args = parser.parse_args()
root = pathlib.Path(__file__).resolve().parents[2]
path = args.receipt or root / 'apple/docs/FRAME_DELIVERY_BROKER_2026-10-22.json'
receipt = json.loads(path.read_text())
checks = 0

def require(value, label):
    global checks
    if not value:
        raise AssertionError(label)
    checks += 1

def check_bytes(data, item):
    require(len(data) == item['bytes'], 'size: ' + item['path'])
    require(hashlib.sha256(data).hexdigest() == item['sha256'], 'SHA256: ' + item['path'])

for item in receipt['sources']:
    data = subprocess.check_output(['git', 'show', item['commit'] + ':' + item['path']], cwd=root)
    check_bytes(data, item)
for item in receipt['bindings']:
    check_bytes(pathlib.Path(item['path']).read_bytes(), item)
inventory = json.loads(pathlib.Path(receipt['compilerInputInventory']).read_text())
require(len(inventory) == receipt['compilerInputCount'], 'compiler input count')
for item in inventory:
    check_bytes(pathlib.Path(item['path']).read_bytes(), item)

base = pathlib.Path(receipt['runs'][0]['binary']['path']).parent.parent
production = (base / 'production/FrameDeliveryBroker.swift').read_bytes()
engine = (base / 'production/CompositionEngine.swift').read_bytes()
require(engine.count(b'// CLOCK_AUTHORITY_GUARD') == 2, 'both actual clock guards retained')
original_clock = subprocess.check_output(['git', 'show', receipt['sourceCommit'] + ':apple/scripts/composition_clock_authority_harness.swift'], cwd=root)
expected_clock = original_clock.replace(b'@main enum CompositionClockAuthorityHarness', b'enum CompositionClockAuthorityHarness')
expected = {
    'production': production,
    'alias-negative': production.replace(b'return CompositedFrame(sampleBuffer: sample,', b'return CompositedFrame(sampleBuffer: source.sampleBuffer,'),
    'sequence-negative': production.replace(b'ring.first(where: { $0.id == intent.publication })?.frame', b'ring.first(where: { $0.frame.sequence == intent.sequence })?.frame'),
}
for run in receipt['runs']:
    label = run['label']
    folder = base / label
    require((folder / 'FrameDeliveryBroker.swift').read_bytes() == expected[label], label + ': only exact intended source alteration')
    require((folder / 'CompositionEngine.swift').read_bytes() == engine, label + ': identical actual Engine')
    require((folder / 'clock_cases.swift').read_bytes() == expected_clock, label + ': unchanged six clock cases except @main')
    require(run['processResult']['exitCode'] == (0 if label == 'production' else -5), label + ': expected actual process result')
    require(run['processResult']['expectedFailure'] == (label != 'production'), label + ': expected result classification')
    check_bytes((folder / 'FrameDeliveryBrokerHarness').read_bytes(), run['binary'])
    if label == 'production':
        require(len(run['passedCases']) == 18, 'all eighteen production cases')

positive = receipt['productionRawHolderObservation']
negative = receipt['originalAliasNegativeObservation']
require(positive['attempts'] == 12 and positive['rendered'] == 12 and positive['failed'] == 0, 'positive actual source pool4 render continuation')
require(positive['healthy'] == list(range(1, 13)), 'positive healthy recipient completeness')
require(positive['heldCounts'] == [4] * 4 and positive['privateCapacityDrops'] == [8] * 4, 'four independent private-bank exhaustion counters')
require(positive['unchangedPrivatePixels'], 'held extracted private pixels unchanged')
require(negative['attempts'] == 12 and negative['rendered'] == 4 and negative['failed'] == 8, 'source-alias negative actual source starvation')
require(negative['healthy'] == [1, 2, 3, 4], 'same healthy assertion rejects origin alias')
print(f'PASS: {checks} source, artifact, compiler-input, exact-control and native-result checks; no runtime/build/benchmark executed')
