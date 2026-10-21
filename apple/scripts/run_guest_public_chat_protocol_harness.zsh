#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly PUBLIC_CHAT_DIR="build/guest-public-chat-protocol-validation"
mkdir -p "$PUBLIC_CHAT_DIR"
xcrun swiftc -swift-version 6 -parse-as-library StreamMac/GuestMediaReceipts.swift \
  scripts/guest_public_chat_protocol_harness.swift -o "$PUBLIC_CHAT_DIR/harness"
"$PUBLIC_CHAT_DIR/harness"
