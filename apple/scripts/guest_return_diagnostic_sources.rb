# Only generated validation-tool copies gain observers; shipping files stay
# byte-identical. Fail if a seam moves rather than silently missing a boundary.
module StreamGuestReturnDiagnosticSources
  def self.apply(target, root, folder)
    replace = lambda do |text, old, new|
      abort "Return diagnostic source seam changed: #{old.lines.first}" unless text.scan(old).length == 1
      text.sub(old, new)
    end
    original_adapter = File.read(File.join(root, 'StreamMac/NativeInterviewReceiverAdapter.swift'))
    audio_start = original_adapter.index('private final class NativeGuestReturnSender:') or abort 'Audio sender class changed'
    audio_end = original_adapter.index('final class NativeGuestReturnVideoSender:') or abort 'Video sender class changed'
    adapter = original_adapter[audio_start...audio_end]
    age = '        let age = (CMClockGetTime(CMClockGetHostTimeClock()) - frame.pts).seconds'
    adapter = replace.call(adapter, age, age + "\n        ReturnSenderDiagnostic.shared.receive(frame, age: age)")
    admission = '        guard isActive(), age >= 0, age <= 0.25, let native = receiver, callbacks.permitsReturn(native) else { return }'
    adapter = replace.call(adapter, admission, admission + "\n        ReturnSenderDiagnostic.shared.admit(frame)")
    sent = '                if sent && !reportedReady {'
    adapter = replace.call(adapter, sent, "                ReturnSenderDiagnostic.shared.packet(packet, sent: sent)\n" + sent)
    failed = '            close(); _ = events(.returnAudio(.failed))'
    adapter = replace.call(adapter, failed, "            ReturnSenderDiagnostic.shared.failed()\n" + failed)
    adapter = original_adapter[0...audio_start] + adapter + original_adapter[audio_end..]
    path = File.join(folder, 'fixtures/DiagnosticInterviewReceiverAdapter.swift')
    File.write(path, adapter)
    target['sources'][0]['excludes'] << 'NativeInterviewReceiverAdapter.swift'
    target['sources'] << path
    target['sources'] << File.join(root, 'scripts/guest_return_sender_diagnostics.swift')
    cli = File.read(File.join(root, 'scripts/native_interview_return_video_cli.swift'))
    state = '                    state["av"] = current.av.snapshot(); state["authoredAV"] = current.toneCue.snapshot()'
    cli = replace.call(cli, state, state + "\n                    state[\"returnAudioDiagnostic\"] = ReturnSenderDiagnostic.shared.snapshot()")
    command = '                case "create":'
    query = <<'SWIFT'
                case "audio-diagnostic":
                    let receipt = try await Task.detached(priority: .utility) {
                        try JSONSerialization.data(withJSONObject: ReturnSenderDiagnostic.shared.snapshot(decode: true))
                    }.value
                    _ = output.emit(["type": "audio-diagnostic", "receipt": try JSONSerialization.jsonObject(with: receipt)])
SWIFT
    cli = replace.call(cli, command, query + command)
    cli_path = File.join(folder, 'fixtures/DiagnosticInterviewReturnVideoCLI.swift')
    File.write(cli_path, cli)
    target['sources'] << cli_path
  end
end
