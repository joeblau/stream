import Foundation
import Security

// Credentials travel only over stdin/stdout pipes, never command arguments,
// Stream Deck settings, project profiles, or logs.
let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                           kSecAttrService as String: "com.joeblau.StreamDeck.StreamStudio",
                           kSecAttrAccount as String: "paired-controller.v1"]
func fail(_ status: OSStatus) -> Never {
    FileHandle.standardError.write(Data("Keychain operation failed (\(status)).\n".utf8))
    exit(1)
}
switch CommandLine.arguments.dropFirst().first {
case "read":
    var read = query; read[kSecReturnData as String] = true; read[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(read as CFDictionary, &result)
    guard status == errSecSuccess, let data = result as? Data else { fail(status) }
    FileHandle.standardOutput.write(data)
case "store":
    // Stop reading after the permitted frame size, even for a malformed pipe.
    let data = FileHandle.standardInput.readData(ofLength: 4097)
    guard data.count <= 4096,
          let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          value["version"] as? Int == 1,
          let id = value["clientID"] as? String, UUID(uuidString: id) != nil,
          let token = value["token"] as? String, token.count == 64,
          token.allSatisfy({ "0123456789abcdef".contains($0) }),
          (value["host"] as? String ?? "127.0.0.1") == "127.0.0.1" else { fail(errSecParam) }
    let update: [String: Any] = [kSecValueData as String: data]
    var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
    if status == errSecItemNotFound {
        var add = query; add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        status = SecItemAdd(add as CFDictionary, nil)
    }
    if status != errSecSuccess { fail(status) }
case "delete":
    let status = SecItemDelete(query as CFDictionary)
    if status != errSecSuccess && status != errSecItemNotFound { fail(status) }
default: fail(errSecParam)
}
