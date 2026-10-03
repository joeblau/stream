# Generated, tool-only credential/default boundaries. Shipping admission,
# mixer, renderer, recording and persistence code remains unchanged.
module StreamGuestFixtureBoundaries
  def self.apply(core, desktop, root, folder)
    desktop['settings'] ||= {}
    desktop['settings']['base'] ||= {}
    desktop['settings']['base']['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = '$(inherited) STREAM_NATIVE_VALIDATION'
    fixture_root = File.join(File.expand_path(folder), 'fixtures')
    require 'fileutils'
    FileUtils.mkdir_p(fixture_root)
    keychain = File.read(File.join(root, 'StreamCore/KeychainStore.swift'))
    prefix = keychain.split('    private let service: String', 2).first
    abort 'Guest Keychain fixture boundary changed' if prefix == keychain
    credential_path = File.join(fixture_root, 'KeychainStore.swift')
    File.write(credential_path, prefix + <<'SWIFT')
    public init(service: String = AppGroup.keychainService) {}
    @discardableResult public func set(_ value: String, for item: Item) -> Bool { true }
    public func string(for item: Item) -> String? { nil }
    public func remove(_ item: Item) {}
}
SWIFT
    core['sources'] = [{'path' => File.join(root, 'StreamCore'), 'excludes' => ['KeychainStore.swift']}, credential_path]
    excluded = ['StreamMacApp.swift']
    generated = []
    Dir.glob(File.join(root, 'StreamMac/**/*.swift')).each do |path|
      next if path.end_with?('/StreamMacApp.swift')
      source = File.read(path)
      original = source.dup
      source.gsub!('UserDefaults.standard', 'GuestFixtureDefaults.value')
      source.gsub!(/UserDefaults\s*=\s*\.standard/, 'UserDefaults = GuestFixtureDefaults.value')
      if path == File.join(root, 'StreamMac/DesktopStorage.swift')
        machine = /    static let machineDirectory: URL = \{.*?\n    \}\(\)/m
        migration = /    func migrateLegacyIfNeeded\(\) \{.*?\n    \}/m
        abort 'Guest desktop storage boundary changed' unless source.match?(machine) && source.match?(migration)
        source.sub!(machine, '    static let machineDirectory: URL = GuestFixtureStorage.machineDirectory')
        source.sub!(migration, "    func migrateLegacyIfNeeded() {\n        if !FileManager.default.fileExists(atPath: url.path) { saveNonSecret(.default) }\n    }")
      end
      next if source == original
      relative = path.delete_prefix(File.join(root, 'StreamMac') + '/')
      copy = File.join(fixture_root, 'Mac', relative)
      FileUtils.mkdir_p(File.dirname(copy))
      File.write(copy, source)
      excluded << relative
      generated << copy
    end
    support = File.join(fixture_root, 'GuestFixtureEnvironment.swift')
    File.write(support, <<'SWIFT')
import Foundation

enum GuestFixtureDefaults {
    static let name = "com.joeblau.Stream.fixture.guest.\(UUID().uuidString)"
    nonisolated(unsafe) static let value: UserDefaults = {
        let defaults = UserDefaults(suiteName: name)!
        atexit { GuestFixtureDefaults.value.removePersistentDomain(forName: GuestFixtureDefaults.name) }
        return defaults
    }()
}
enum GuestFixtureStorage {
    static let machineDirectory: URL = {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("stream-guest-fixture-machine-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        atexit { try? FileManager.default.removeItem(at: GuestFixtureStorage.machineDirectory) }
        return directory
    }()
}
SWIFT
    desktop['sources'][0] = {'path' => File.join(root, 'StreamMac'), 'excludes' => excluded}
    desktop['sources'].concat(generated + [support])
    require File.join(root, 'scripts/desktop_transport_fixture')
    StreamDesktopTransportFixture.apply(desktop, root)
  end
end
