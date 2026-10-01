import Foundation
import CoreGraphics
import Darwin

/// Read-only runtime/SDK diagnosis. It neither installs vendor software nor
/// claims successful discovery/capture without the SDK bridge and hardware.
func header(named name: String, root: String?) -> String? {
    guard let root, let iterator = FileManager.default.enumerator(atPath:root) else { return nil }
    var visited = 0
    while let path = iterator.nextObject() as? String, visited < 8192 {
        visited += 1
        if (path as NSString).lastPathComponent == name { return URL(fileURLWithPath:root).appendingPathComponent(path).path }
    }
    return nil
}
func runtime(paths:[String], symbols:[String]) -> [String:Any] {
    guard let path = paths.first(where: { FileManager.default.fileExists(atPath:$0) }) else {
        return ["status":"missing","captureValidated":false]
    }
    guard let library = dlopen(path,RTLD_LOCAL|RTLD_NOW) else {
        return ["status":"loadFailed","path":path,"error":dlerror().map { String(cString:$0) } ?? "Unknown loader error","captureValidated":false]
    }
    defer { dlclose(library) }
    var output:[String:Any] = ["status":"loadable","path":path,"captureValidated":false,
                              "symbols":Dictionary(uniqueKeysWithValues:symbols.map { ($0,dlsym(library,$0) != nil) })]
    if let version = dlsym(library,"NDIlib_version") {
        typealias Version = @convention(c) () -> UnsafePointer<CChar>?
        if let value = unsafeBitCast(version,to:Version.self)() { output["version"] = String(cString:value) }
    }
    return output
}
let environment = ProcessInfo.processInfo.environment
let ndiPaths = [environment["STREAM_NDI_RUNTIME"],
    "/Library/NDI SDK for Apple/lib/macOS/libndi.dylib", "/Library/NDI SDK for Apple/lib/macOS/libndi.6.dylib",
    "/usr/local/lib/libndi.dylib", "/opt/homebrew/lib/libndi.dylib"].compactMap { $0 }
let deckPaths = [environment["STREAM_DECKLINK_RUNTIME"],
    "/Library/Frameworks/DeckLinkAPI.framework/DeckLinkAPI"].compactMap { $0 }
var ndi = runtime(paths:ndiPaths,symbols:["NDIlib_initialize","NDIlib_find_create_v2","NDIlib_recv_create_v3","NDIlib_recv_capture_v2"])
ndi["sdkHeader"] = header(named:"Processing.NDI.Lib.h",root:environment["STREAM_NDI_SDK_ROOT"] ?? "/Library/NDI SDK for Apple") ?? "missing"
var deck = runtime(paths:deckPaths,symbols:["CreateDeckLinkIteratorInstance"])
deck["sdkHeader"] = header(named:"DeckLinkAPI.h",root:environment["STREAM_DECKLINK_SDK_ROOT"]) ?? "missing"
let report:[String:Any] = ["recordedAt":ISO8601DateFormatter().string(from:Date()),
                          "os":ProcessInfo.processInfo.operatingSystemVersionString,
                          "ndi":ndi,"deckLink":deck,
                          "screenCapturePermission":CGPreflightScreenCaptureAccess(),
                          "result":"Prerequisite diagnosis only; SDK ABI, driver/hardware capture, timestamps and reconnect remain unqualified."]
let data = try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
print(String(decoding:data,as:UTF8.self))
