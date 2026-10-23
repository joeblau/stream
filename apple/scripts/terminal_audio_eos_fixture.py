#!/usr/bin/env python3
"""Prepare exact-parent/fixed actual-writer sources, then run each once explicitly."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys

BASE = "9f9f6bc6f4aa81c4ba1d0e92e096047741d9bfb7"
SDK_HEADER = Path("/Applications/Xcode-27.1.0.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks/AVFoundation.framework/Versions/A/Headers/AVAssetWriterInput.h")
DEPENDENCIES = [
    "RawVideoResourceCoordinator.swift", "FrameDeliveryBroker.swift", "FrameDeliveryConverter.swift",
    "RecordingFrameDelivery.swift", "IsolatedRecordingTypes.swift", "IsolatedVideoTypes.swift",
    "RecordingChatPaint.swift", "RecordingChatTypes.swift", "RecordingChatArchive.swift",
    "RecordingChatReader.swift", "RecordingPreferences.swift",
]


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def replace_once(source, before, after):
    assert source.count(before) == 1, repr(before)
    return source.replace(before, after)


def instrument(source):
    source = replace_once(source, "        var frameRate: Int = 30\n",
                          "        var validationHeldVideoPTS: CMTime?\n        var frameRate: Int = 30\n")
    source = replace_once(source, "    private var videoInputFinished = false\n", """    private var videoInputFinished = false
    private var validationAudioEOSCalls = 0
    struct ValidationSnapshot: Sendable {
        let progress: Progress
        let videoEmpty: Bool
        let audioEmpty: Bool
        let acceptingAudio: Bool
        let audioEOSCalls: Int
        let finishRequested: Bool
        let awaitingFinishBoundary: Bool
        let finishing: Bool
    }
    func validationSnapshot() async -> ValidationSnapshot {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                updateProgress()
                lock.lock()
                let snapshot = ValidationSnapshot(progress: progress, videoEmpty: video.isEmpty,
                    audioEmpty: audio.isEmpty, acceptingAudio: acceptingAudio,
                    audioEOSCalls: validationAudioEOSCalls, finishRequested: finishRequested,
                    awaitingFinishBoundary: awaitingFinishBoundary, finishing: finishing)
                lock.unlock()
                continuation.resume(returning: snapshot)
            }
        }
    }
""")
    source = replace_once(source,
                          "            let nextVideo = videoInput.isReadyForMoreMediaData ? video.first : nil\n", """            // Controlled SDK-contract gate. The harness introduces this final
            // frame ONLY after observing real 59-video/100-audio accepted media.
            let validationVideoReleased: Bool
            if let heldPTS = configuration.validationHeldVideoPTS,
               let pending = video.first, pending.presentationTimeStamp >= heldPTS {
                validationVideoReleased = validationAudioEOSCalls > 0
            } else { validationVideoReleased = true }
            let nextVideo = videoInput.isReadyForMoreMediaData && validationVideoReleased ? video.first : nil
""")
    # Observe the actual non-nil native call, not audioInputFinished or a formula.
    optional = "audioInput?.markAsFinished()"
    assert source.count(optional) == 1
    source = source.replace(optional, "if let audioInput { audioInput.markAsFinished(); validationAudioEOSCalls += 1 }")
    direct = "if audioEmpty { audioInput.markAsFinished() }"
    assert source.count(direct) in (0, 1)
    source = source.replace(direct, "if audioEmpty { audioInput.markAsFinished(); validationAudioEOSCalls += 1 }")
    return source


def prepare(root, out, framework, receipt_path):
    assert not out.exists(), "Use a fresh proof directory; retained outcomes are immutable."
    core_receipt = json.loads(receipt_path.read_text())
    expected = core_receipt["positiveCoreSourceSHA256"]
    actual_paths = sorted(str(path.relative_to(root)) for path in (root / "apple/StreamCore").glob("*.swift"))
    assert len(expected) == 76 and actual_paths == sorted(expected)
    for path, digest in expected.items():
        assert sha(root / path) == digest, path
    assert sha(framework / "StreamCore") == core_receipt["positiveFrameworkSHA256"]
    out.mkdir(parents=True)
    products = out / "products"
    products.mkdir()
    shutil.copytree(framework, products / "StreamCore.framework", symlinks=True)
    common = out / "common"
    common.mkdir()
    bindings = {}
    for name in DEPENDENCIES:
        path = root / "apple/StreamMac" / name
        shutil.copy2(path, common / name)
        bindings[str(path)] = sha(path)
    for name in ["program_recording_fixtures.swift", "terminal_audio_eos_harness.swift"]:
        path = root / "apple/scripts" / name
        shutil.copy2(path, common / name)
        bindings[str(path)] = sha(path)
    relative = "apple/StreamMac/ProgramRecordingSession.swift"
    old = subprocess.run(["git", "show", f"{BASE}:{relative}"], cwd=root, check=True, capture_output=True).stdout
    fixed = (root / relative).read_bytes()
    for name, data in [("parent", old), ("fixed", fixed)]:
        phase = out / name
        phase.mkdir()
        (phase / "ProgramRecordingSession.original.swift").write_bytes(data)
        (phase / "ProgramRecordingSession.swift").write_text(instrument(data.decode()))
    bindings[str(root / relative)] = sha(root / relative)
    bindings[str(root / "apple/scripts/terminal_audio_eos_fixture.py")] = sha(root / "apple/scripts/terminal_audio_eos_fixture.py")
    manifest = dict(base=BASE, scope="Actual AVAssetWriter contract test with an injected final-video readiness gate; not a reproduction or causal attribution of the original Intel failure.",
                    sdkHeader=str(SDK_HEADER), sdkHeaderSHA256=sha(SDK_HEADER),
                    coreReceipt=str(receipt_path), coreReceiptSHA256=sha(receipt_path), coreSources=expected,
                    frameworkSHA256=sha(framework / "StreamCore"), sourceBindings=bindings,
                    generated={str(path.relative_to(out)): sha(path) for path in sorted(out.rglob("*.swift"))},
                    productionChanges="terminal drained-audio EOS and idempotent finalize only; parent is exact git-show bytes, not a synthesized old implementation",
                    runtimeGuardSeconds=45, setupWaitSeconds=5, productionFinishSeconds=3,
                    runs="One fixed and one exact-parent invocation; no retries. Stop if any setup phase fails.")
    (out / "prepared.json").write_text(json.dumps(manifest, indent=2) + "\n")


def invoke(command, log, timeout, env=None):
    try:
        with log.open("wb") as output:
            result = subprocess.run(command, stdout=output, stderr=subprocess.STDOUT, timeout=timeout, env=env)
        return {"exit": result.returncode, "timedOut": False}
    except subprocess.TimeoutExpired:
        return {"exit": None, "timedOut": True}


def run(out):
    import os
    manifest = json.loads((out / "prepared.json").read_text())
    for path, digest in manifest["generated"].items():
        assert sha(out / path) == digest, path
    assert not (out / "outcomes.json").exists(), "Never overwrite or retry outcomes."
    products = out / "products"
    assert sha(products / "StreamCore.framework/StreamCore") == manifest["frameworkSHA256"]
    results = {}
    try:
        for name in ["fixed", "parent"]:
            phase = out / name
            executable = phase / "terminal-audio-eos"
            command = ["xcrun", "swiftc", "-j2", "-swift-version", "6", "-strict-concurrency=complete", "-parse-as-library",
                       "-F", str(products), "-framework", "StreamCore", "-Xlinker", "-rpath", "-Xlinker", str(products)]
            command += [str(out / "common" / filename) for filename in DEPENDENCIES]
            command += [str(phase / "ProgramRecordingSession.swift"), str(out / "common/program_recording_fixtures.swift"),
                        str(out / "common/terminal_audio_eos_harness.swift"), "-o", str(executable)]
            (phase / "compile-command.json").write_text(json.dumps(command, indent=2) + "\n")
            results[name] = {"compile": invoke(command, phase / "compile.log", 180)}
            if results[name]["compile"] != {"exit": 0, "timedOut": False}:
                raise RuntimeError(f"{name} compile failed; preserve first outcome")
            env = os.environ.copy()
            env["STREAM_FIXTURE_AUDIO_DECODER"] = "av-audio-file"
            results[name]["runtime"] = invoke([str(executable), str(phase / "media")], phase / "runtime.log", 45, env)
            log = (phase / "runtime.log").read_text(errors="replace")
            if name == "fixed":
                assert results[name]["runtime"] == {"exit": 0, "timedOut": False}, "Fixed runtime failed; no parent run/retry."
                assert "PASS terminal audio EOS:" in log and "PASS held actual99+1PCM tail:" in log
            else:
                assert not results[name]["runtime"]["timedOut"] and results[name]["runtime"]["exit"] in (-4, -5)
                assert "RESULT terminal-eos completed=false video=59 audio=100 audioEOS=1 error=Program audio or video did not drain to the recording boundary before its finalization deadline." in log
                assert "Terminal audio EOS did not unblock final video" in log
            results[name]["executableSHA256"] = sha(executable)
    finally:
        (out / "outcomes.json").write_text(json.dumps(results, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("operation", choices=["prepare", "run"])
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--framework", type=Path)
    parser.add_argument("--core-receipt", type=Path)
    args = parser.parse_args()
    if args.operation == "prepare":
        assert args.framework and args.core_receipt
        prepare(Path(__file__).resolve().parents[2], args.output.resolve(), args.framework.resolve(), args.core_receipt.resolve())
    else:
        run(args.output.resolve())


if __name__ == "__main__":
    main()
