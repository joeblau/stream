#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly CHAT_DIR="build/studio-chat-validation"
mkdir -p "$CHAT_DIR"
swiftc -swift-version 6 -parse-as-library StreamMac/StudioChatModel.swift \
  scripts/studio_chat_harness.swift -o "$CHAT_DIR/harness"
"$CHAT_DIR/harness"
