import Foundation
import CoreGraphics
import Darwin
import CryptoKit

/// Read-only runtime/SDK diagnosis. It neither installs vendor software nor
/// claims successful discovery/capture without the SDK bridge and hardware.
func header(named name: String, root: String?) -> String? {
    guard let root, let iterator = FileManager.default.enumerator(atPath:root) else { return nil }
    var visited = 0
    while let path = iterator.nextObject() as? String, visited < 8192 {
        visited += 1
        if (path as NSString).lastPathComponent == name {
            let candidate = URL(fileURLWithPath:root).appendingPathComponent(path).path
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory), !isDirectory.boolValue,
               FileManager.default.isReadableFile(atPath: candidate) { return candidate }
        }
    }
    return nil
}
func runtime(paths:[String], symbols:[String]) -> [String:Any] {
    guard let path = paths.first(where: { FileManager.default.fileExists(atPath:$0) }) else {
        return ["status":"missing","captureValidated":false]
    }
    guard let library = dlopen(path,RTLD_LOCAL|RTLD_NOW) else {
        return ["status":"loadFailed","path":path,"error":dlerror().map { String(cString:$0) } ?? "Unknown loader error","captureValidated":false,"artifact":artifact(path:path)]
    }
    defer { dlclose(library) }
    var output:[String:Any] = ["status":"loadable","path":path,"captureValidated":false,
                              "symbols":Dictionary(uniqueKeysWithValues:symbols.map { ($0,dlsym(library,$0) != nil) })]
    output["artifact"] = artifact(path: path)
    if let version = dlsym(library,"NDIlib_version") {
        typealias Version = @convention(c) () -> UnsafePointer<CChar>?
        if let value = unsafeBitCast(version,to:Version.self)() { output["version"] = String(cString:value) }
    }
    return output
}
/// Inspect the artifact without spawning a shell, installing it, or loading a
/// framework from another application's private bundle.
func artifact(path: String) -> [String: Any] {
    guard let handle = FileHandle(forReadingAtPath: path) else { return ["status": "unreadable", "path": path] }
    defer { try? handle.close() }
    do {
        var digest = SHA256()
        var bytes = 0
        var prefix = Data()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            bytes += chunk.count
            if prefix.isEmpty { prefix = Data(chunk.prefix(4096)) }
            guard bytes <= 1_073_741_824 else { return ["status": "tooLarge", "path": path] }
            digest.update(data: chunk)
        }
        return ["status": "readable", "path": path, "bytes": bytes, "architectures": architectures(prefix),
                "sha256": digest.finalize().map { String(format: "%02x", $0) }.joined()]
    } catch { return ["status": "readFailed", "path": path] }
}
func architectures(_ header: Data) -> [String] {
    let bytes = Array(header)
    func word(_ offset: Int, little: Bool = false) -> UInt32? {
        guard offset >= 0, offset + 4 <= bytes.count else { return nil }
        let values = Array(bytes[offset..<offset + 4])
        return (little ? Array(values.reversed()) : values).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
    func name(_ cpu: UInt32) -> String { cpu == 0x0100000c ? "arm64" : cpu == 0x01000007 ? "x86_64" : String(format: "cpu-0x%08x", cpu) }
    guard let magic = word(0) else { return [] }
    if magic == 0xcffaedfe || magic == 0xcefaedfe, let cpu = word(4, little: true) { return [name(cpu)] }
    if magic == 0xfeedfacf || magic == 0xfeedface, let cpu = word(4) { return [name(cpu)] }
    guard magic == 0xcafebabe || magic == 0xcafebabf, let count = word(4), count <= 64 else { return [] }
    let stride = magic == 0xcafebabf ? 32 : 20
    return (0..<Int(count)).compactMap { word(8 + $0 * stride).map(name) }
}
func paths(override: String?, defaults: [String]) -> [String] {
    // An explicitly selected missing SDK must not silently select another
    // installation and accidentally qualify a different version.
    if let override { return [override] }
    return defaults
}
func symbolsPresent(_ report: [String: Any], _ names: [String]) -> Bool {
    guard report["status"] as? String == "loadable", let found = report["symbols"] as? [String: Bool] else { return false }
    return names.allSatisfy { found[$0] == true }
}
let environment = ProcessInfo.processInfo.environment
let ndiPaths = paths(override: environment["STREAM_NDI_RUNTIME"], defaults: [
    "/Library/NDI SDK for Apple/lib/macOS/libndi.dylib", "/Library/NDI SDK for Apple/lib/macOS/libndi.6.dylib",
    "/usr/local/lib/libndi.dylib", "/opt/homebrew/lib/libndi.dylib"])
let deckPaths = paths(override: environment["STREAM_DECKLINK_RUNTIME"], defaults: [
    "/Library/Frameworks/DeckLinkAPI.framework/DeckLinkAPI"])
let ndiReceive = ["NDIlib_initialize", "NDIlib_destroy", "NDIlib_find_create_v2", "NDIlib_find_destroy", "NDIlib_find_get_current_sources",
    "NDIlib_recv_create_v3", "NDIlib_recv_destroy", "NDIlib_recv_capture_v2", "NDIlib_recv_free_video_v2", "NDIlib_recv_free_audio_v2",
    "NDIlib_recv_free_metadata", "NDIlib_recv_set_tally", "NDIlib_recv_get_performance"]
let ndiSend = ["NDIlib_initialize", "NDIlib_destroy", "NDIlib_send_create", "NDIlib_send_destroy", "NDIlib_send_send_video_v2",
    "NDIlib_send_send_audio_v2", "NDIlib_send_get_no_connections", "NDIlib_send_get_tally"]
var ndi = runtime(paths:ndiPaths,symbols:Array(Set(ndiReceive + ndiSend)).sorted())
ndi["sdkHeader"] = header(named:"Processing.NDI.Lib.h",root:environment["STREAM_NDI_SDK_ROOT"] ?? "/Library/NDI SDK for Apple") ?? "missing"
ndi["receiveSymbolsPresent"] = symbolsPresent(ndi, ndiReceive)
ndi["sendSymbolsPresent"] = symbolsPresent(ndi, ndiSend)
ndi["checkedPaths"] = ndiPaths
var deck = runtime(paths:deckPaths,symbols:["CreateDeckLinkIteratorInstance"])
deck["sdkHeader"] = header(named:"DeckLinkAPI.h",root:environment["STREAM_DECKLINK_SDK_ROOT"]) ?? "missing"
deck["checkedPaths"] = deckPaths
deck["standardDriverDirectoryPresent"] = FileManager.default.fileExists(atPath: "/Library/Application Support/Blackmagic Design")
// Zoom's desktop application is not the distributable Meeting SDK. Inspect
// only a separately supplied SDK or the standard SDK framework location.
let zoomRoot = environment["STREAM_ZOOM_SDK_ROOT"]
let zoomFramework = environment["STREAM_ZOOM_FRAMEWORK"] ?? zoomRoot.map { URL(fileURLWithPath: $0).appendingPathComponent("ZoomSDK.framework").path } ?? "/Library/Frameworks/ZoomSDK.framework"
let zoomBundle = Bundle(path: zoomFramework)
var zoom: [String: Any] = ["frameworkPath": zoomFramework,
    "status": FileManager.default.fileExists(atPath: zoomFramework) ? "presentNotLoaded" : "missing",
    "sdkHeader": header(named: "ZoomSDK.h", root: zoomRoot ?? zoomFramework) ?? "missing",
    "desktopClientPresent": FileManager.default.fileExists(atPath: "/Applications/zoom.us.app"),
    "captureValidated": false, "returnValidated": false]
if let executable = zoomBundle?.executableURL { zoom["artifact"] = artifact(path: executable.path) }
if let version = zoomBundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String { zoom["version"] = version }
let gates: [[String: Any]] = [
    ["issues": [160, 176], "adapter": "ndi", "bridgeImplemented": false, "qualified": false,
     "remaining": ["Selected licensed SDK and runtime", "Native receive/send bridge and bounded host-clock audio/video delivery", "Named sender/receiver, tally, reconnect and distribution qualification"]],
    ["issues": [161, 177], "adapter": "deckLink", "bridgeImplemented": false, "qualified": false,
     "remaining": ["Selected Desktop Video SDK, driver and documented hardware", "SDK-header-backed capture and scheduled output bridge", "Measured formats, audio/video clock, signal loss, late frames and signed sandbox qualification"]],
    ["issues": [167, 168], "adapter": "zoom", "bridgeImplemented": false, "qualified": false,
     "remaining": ["Separately distributed Meeting SDK, registered app credentials and authorized meeting/account", "Host-granted raw recording/streaming permissions and participant consent", "Embedded custom UI, isolated audio/video and program return prototype", "Signed architecture/distribution and real meeting/network/capacity qualification"]]
]
let report:[String:Any] = ["schemaVersion": 2, "recordedAt":ISO8601DateFormatter().string(from:Date()),
                          "os":ProcessInfo.processInfo.operatingSystemVersionString,
                          "ndi":ndi,"deckLink":deck,"zoom":zoom,"qualificationGates":gates,
                          "screenCapturePermission":CGPreflightScreenCaptureAccess(),
                          "screenCapturePermissionScope": "Diagnostic process only; not vendor raw-media authorization or shipping app permission.",
                          "result":"Prerequisite diagnosis only; SDK ABI, capture/return, hardware/network clocks, reconnect and distribution remain unqualified."]
let data = try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
print(String(decoding:data,as:UTF8.self))
