// swift-tools-version:5.9
import PackageDescription

// C09 (issue #163): the Syphon framework, vendored as a prebuilt universal
// (arm64 + x86_64) macOS xcframework. Upstream
// https://github.com/Syphon/Syphon-Framework ships NO Package.swift, so SPM
// cannot resolve it as a remote package; a local binary-target package is
// the pinned equivalent. This binary was built from upstream commit
// f4761677a45b8034a3c2069ec0f3d2553da81fba (main, 2026-09-21) with:
//
//   xcodebuild -project Syphon.xcodeproj -scheme Syphon -configuration Release \
//     -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
//   xcodebuild -create-xcframework \
//     -framework <derivedData>/Build/Products/Release/Syphon.framework \
//     -output Syphon.xcframework
//
// Rebuild from the same commit (or a newer pinned one) to update — never
// edit the binary in place. License: BSD-style, see LICENSE.txt alongside.
let package = Package(
    name: "Syphon",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Syphon", targets: ["Syphon"])
    ],
    targets: [
        .binaryTarget(name: "Syphon", path: "Syphon.xcframework")
    ]
)
