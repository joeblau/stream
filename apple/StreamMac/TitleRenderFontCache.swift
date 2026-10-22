import CoreText
import Foundation
import StreamCore

/// Core Text fonts are immutable. Reuse the completed fallback cascade while
/// the request and registry are unchanged; raster/layout keys still resolve
/// from the returned font exactly as before.
final class TitleRenderFontCache {
    struct Selection {
        var font: CTFont
        var generation: UInt64
    }
    private struct Key: Hashable {
        var requested: String?
        var size: CGFloat
    }

    private let capacity: Int
    private let generation: () -> UInt64
    private let makeFont: (String?, CGFloat) -> CTFont
    private var fonts: [Key: CTFont] = [:]
    private var cachedGeneration: UInt64?

    init(capacity: Int = 64,
         generation: @escaping () -> UInt64 = { TitleFontRegistryGeneration.shared.snapshot() },
         makeFont: @escaping (String?, CGFloat) -> CTFont = {
             TitleFontFallback.makeFont(requested: $0, size: $1)
         }) {
        self.capacity = max(1, capacity)
        self.generation = generation
        self.makeFont = makeFont
    }

    /// Confined to its SceneRenderer's executor. Registry callbacks touch only
    /// the separately synchronized generation, never the renderer's cache.
    func registryGeneration() -> UInt64 { generation() }

    func resolve(requested: String?, size: CGFloat) -> Selection {
        let current = generation()
        if current != cachedGeneration {
            fonts.removeAll(keepingCapacity: true)
            cachedGeneration = current
        }
        let key = Key(requested: requested, size: size)
        if let font = fonts[key] { return Selection(font: font, generation: current) }
        let font = makeFont(requested, size)
        // Registration may change while Core Text builds the cascade. Do not
        // retain that result across the change; next use resolves it afresh.
        guard generation() == current else {
            fonts.removeAll(keepingCapacity: true)
            cachedGeneration = nil
            return Selection(font: font, generation: current)
        }
        if fonts.count >= capacity { fonts.removeAll(keepingCapacity: true) }
        fonts[key] = font
        return Selection(font: font, generation: current)
    }
}

/// Core Text posts process-scope changes locally and user/session changes
/// through the distributed center. Observe both so a missing-font fallback
/// is not pinned after installation, activation, removal or deactivation.
private final class TitleFontRegistryGeneration: @unchecked Sendable {
    static let shared = TitleFontRegistryGeneration()

    private let lock = NSLock()
    private var value: UInt64 = 0
    private var preferredLanguages = Locale.preferredLanguages
    private var localeObserver: NSObjectProtocol?

    private static let changed: CFNotificationCallback = { _, observer, _, _, _ in
        guard let observer else { return }
        Unmanaged<TitleFontRegistryGeneration>.fromOpaque(observer)
            .takeUnretainedValue().advance()
    }

    private init() {
        let observer = Unmanaged.passUnretained(self).toOpaque()
        for center in [CFNotificationCenterGetLocalCenter(), CFNotificationCenterGetDistributedCenter()] {
            CFNotificationCenterAddObserver(center, observer, Self.changed,
                kCTFontManagerRegisteredFontsChangedNotification, nil, .deliverImmediately)
        }
        localeObserver = NotificationCenter.default.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.advance() }
    }

    func snapshot() -> UInt64 {
        // The cascade builder uses the preferred-language list when its
        // language argument is nil. Also compare that list so an environment
        // change cannot depend solely on notification delivery ordering.
        let languages = Locale.preferredLanguages
        lock.lock(); defer { lock.unlock() }
        if languages != preferredLanguages {
            preferredLanguages = languages
            value &+= 1
        }
        return value
    }

    private func advance() {
        lock.lock(); value &+= 1; lock.unlock()
    }
}
