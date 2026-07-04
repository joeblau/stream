import Network

/// Reduced, Sendable, Equatable snapshot of an `NWPath`. Equality over these
/// fields is the dedupe key: NWPathMonitor re-emits on DNS/agent/VPN churn
/// that must not disturb a live RTMP/SRT/WHIP session.
///
/// No class wrapper is needed around `NWPathMonitor` itself — on this iOS 26+
/// target the SDK's monitor is `Sendable` and an `AsyncSequence` (Element
/// `NWPath`), so `for await path in NWPathMonitor()` inside an actor task
/// auto-starts the monitor and ends iteration when the task is cancelled
/// (at the next emission at the latest).
///
/// Lives in StreamCore so both publishers (RTMP + the unified SRT/WHIP session)
/// share one path model and its per-path bitrate policy, and so the policy is
/// unit-tested on CI.
public struct NetworkPathSnapshot: Sendable, Equatable {
    public enum Interface: String, Sendable, Hashable {
        case wifi, cellular, wiredEthernet, other, none
    }

    public let isSatisfied: Bool
    public let interface: Interface
    /// "en0" / "pdp_ip0" — included in the link identity so a same-type
    /// interface swap still reads as a handoff.
    public let interfaceName: String
    public let isExpensive: Bool
    public let isConstrained: Bool        // Low Data Mode
    public let isUltraConstrained: Bool   // iOS 26
    public let linkQualityIsMinimal: Bool // iOS 26, reduced to Bool for cheap Equatable

    public init(_ path: NWPath) {
        isSatisfied = path.status == .satisfied
        let usedType: NWInterface.InterfaceType?
        if path.usesInterfaceType(.wifi) {
            interface = .wifi; usedType = .wifi
        } else if path.usesInterfaceType(.cellular) {
            interface = .cellular; usedType = .cellular
        } else if path.usesInterfaceType(.wiredEthernet) {
            interface = .wiredEthernet; usedType = .wiredEthernet
        } else if path.status == .satisfied {
            interface = .other; usedType = nil
        } else {
            interface = .none; usedType = nil
        }
        // Name of the interface actually CARRYING the path (matching the used
        // type) — NOT availableInterfaces.first. That list reorders/adds pdp_ip0
        // when OTHER apps wake the cellular radio, which flipped the identity and
        // triggered a false Wi-Fi→Wi-Fi "handoff" recycle even though the live
        // Wi-Fi link never changed.
        interfaceName = usedType.flatMap { type in
            path.availableInterfaces.first(where: { $0.type == type })?.name
        } ?? ""
        isExpensive = path.isExpensive
        isConstrained = path.isConstrained
        // isUltraConstrained + linkQuality are iOS 26+. StreamCore's deployment
        // floor is iOS 18 (so its tests run on any CI simulator); guard the newer
        // signals and fall back to the unrestricted values below that. The app
        // itself requires iOS 27, so on-device these always read the real values.
        if #available(iOS 26.0, *) {
            isUltraConstrained = path.isUltraConstrained
            linkQualityIsMinimal = path.linkQuality == .minimal
        } else {
            isUltraConstrained = false
            linkQualityIsMinimal = false
        }
    }

    /// Memberwise initializer for tests (no live `NWPath` available off-device).
    public init(isSatisfied: Bool,
                interface: Interface,
                interfaceName: String,
                isExpensive: Bool = false,
                isConstrained: Bool = false,
                isUltraConstrained: Bool = false,
                linkQualityIsMinimal: Bool = false) {
        self.isSatisfied = isSatisfied
        self.interface = interface
        self.interfaceName = interfaceName
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
        self.isUltraConstrained = isUltraConstrained
        self.linkQualityIsMinimal = linkQualityIsMinimal
    }

    /// What "a different link" means for reconnect purposes.
    public var linkIdentity: String { "\(interface.rawValue)/\(interfaceName)" }

    /// Per-path video bitrate ceiling policy. Cellular caps the max so a 3 Mbps
    /// Wi-Fi target is never re-attempted verbatim on a weak cell; Low Data
    /// Mode and iOS 26 link-quality signals cap harder. Numbers are policy,
    /// tunable on device.
    public func videoBitRateCeiling(configuredMaximum maximum: Int) -> Int {
        guard isSatisfied else { return maximum }
        var ceiling = maximum
        if interface == .cellular || isExpensive { ceiling = min(ceiling, 2_500_000) }
        if isConstrained { ceiling = min(ceiling, 1_200_000) }
        if isUltraConstrained { ceiling = min(ceiling, 800_000) }
        if linkQualityIsMinimal { ceiling = Swift.max(300_000, ceiling / 2) }
        return ceiling
    }
}
