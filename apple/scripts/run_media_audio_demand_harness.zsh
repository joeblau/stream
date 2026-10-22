#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly DEMAND_BUILD="${MEDIA_DEMAND_BUILD_DIR:-build/media-audio-demand-validation}"
readonly DEMAND_FRAMEWORKS="${MEDIA_DEMAND_FRAMEWORKS:-build/deck-audio-media-validation/derived/Build/Products/Debug}"
[[ -d "$DEMAND_FRAMEWORKS/StreamCore.framework" ]] || { print -u2 'Build the deck audio/media fixture first, or set MEDIA_DEMAND_FRAMEWORKS to the matching StreamCore products.'; exit 77; }
mkdir -p "$DEMAND_BUILD"
xcrun swiftc -j2 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  -target "$(uname -m)-apple-macos14.0" -F "$DEMAND_FRAMEWORKS" -framework StreamCore \
  StreamMac/GuestMediaReceipts.swift StreamMac/IsolatedRecordingTypes.swift StreamMac/IsolatedVideoTypes.swift \
  StreamMac/RecordingChatTypes.swift StreamMac/RecordingChatArchive.swift StreamMac/RecordingChatReader.swift \
  StreamMac/RecordingPreferences.swift StreamMac/ProgramRecordingSession.swift StreamMac/AudioMixEngine.swift \
  StreamMac/MediaAudioChannelDemand.swift scripts/program_recording_fixtures.swift \
  scripts/media_audio_demand_harness.swift -o "$DEMAND_BUILD/harness"
env DYLD_FRAMEWORK_PATH="${DEMAND_FRAMEWORKS:A}" "$DEMAND_BUILD/harness"
