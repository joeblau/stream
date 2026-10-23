#!/usr/bin/env python3
"""Prepare a reversible fixture-only controller copy; never alter shipping code.

The receipt binds both complete source bytes, each exact insertion and the helper.
This preparation does not build or run the harness. A new shipping preimage must
still match all anchors; changed anchor counts fail closed before project creation.
"""
import hashlib
import json
import pathlib
import sys


def sha(data):
    return hashlib.sha256(data).hexdigest()


def prepare(folder):
    root = pathlib.Path(__file__).resolve().parent.parent
    source = root / "StreamMac/DestinationOutputController.swift"
    helper = root / "scripts/SharedEncoderStopDiagnostics.swift"
    original = source.read_bytes()
    text = original.decode("utf-8")
    changes = []

    def replace(old, new):
        nonlocal text
        if text.count(old) != 1:
            raise ValueError("Expected exactly one diagnostic source anchor: " + old)
        text = text.replace(old, new, 1)
        changes.append({"before": old, "after": new})

    identity = ('["outputID": id.uuidString, "generation": runtime.generation.uuidString, '
                '"transport": runtime.destination.transport.rawValue')
    for indentation, path in (("            ", "stop"), ("                ", "failure")):
        original_line = "\n" + indentation + "await runtime.publisher.stop()\n"
        prefix = 'SharedEncoderStopDiagnostics.record("publisher.stop.' + path + '", '
        replace(original_line,
                "\n" + indentation + prefix + '"BEGIN", fields: ' + identity + ', "status": "invoked"])\n'
                + original_line[1:]
                + indentation + prefix + '"END", fields: ' + identity + ', "status": "returnedVoid"])\n')

    original_line = "        let drained = await mailbox.finish()\n"
    replace(original_line,
            '        SharedEncoderStopDiagnostics.record("encodedMailbox.finish", "BEGIN", fields: '
            + identity + ', "encoderFinished": String(encoderFinished)])\n'
            + original_line
            + '        SharedEncoderStopDiagnostics.record("encodedMailbox.finish", "END", fields: '
            + identity + ', "encoderFinished": String(encoderFinished), "drained": String(drained)])\n')
    original_line = "            let ownsStop = self.pendingStops[id]?.generation == runtime.generation\n"
    replace(original_line, original_line
            + '            SharedEncoderStopDiagnostics.record("controller.stopReceipt", "OBSERVED", fields: '
            + identity + ', "receipt": self.finishedStops[runtime.generation]?.rawValue ?? "absent", '
            '"ownsPendingStop": String(ownsStop)])\n')

    reversed_text = text
    for change in reversed(changes):
        if reversed_text.count(change["after"]) != 1:
            raise ValueError("Nonunique diagnostic reversal")
        reversed_text = reversed_text.replace(change["after"], change["before"], 1)
    if reversed_text.encode("utf-8") != original:
        raise ValueError("Diagnostic transform is not byte reversible")
    generated = text.encode("utf-8")
    folder.mkdir(parents=True, exist_ok=True)
    (folder / "DestinationOutputController.preimage.swift").write_bytes(original)
    (folder / "DestinationOutputController.swift").write_bytes(generated)
    receipt = {"scope": "fixture-only stop observations; not a shipping behavior fix",
               "preimage": {"path": str(source), "sha256": sha(original)},
               "generatedSHA256": sha(generated), "reversedSHA256": sha(reversed_text.encode("utf-8")),
               "helper": {"path": str(helper), "sha256": sha(helper.read_bytes())},
               "generatorSHA256": sha(pathlib.Path(__file__).read_bytes()), "changes": changes,
               "observerEventLimit": 512, "nativeExecutionPerformedByPreparation": False,
               "statusScope": "publisher.stop returns Void; receipt is controller-local; receiver exit is callback-observed"}
    (folder / "source-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")


if __name__ == "__main__":
    prepare(pathlib.Path(sys.argv[1]).resolve() / "stop-diagnostics")
