import Network

/// Reduced, Sendable, Equatable snapshot of an `NWPath`. Equality over these
/// fields is the dedupe key: NWPathMonitor re-emits on DNS/agent/VPN churn
/// that must not disturb a live RTMP session.
///
/// No class wrapper is needed around `NWPathMonitor` itself — on this iOS 26+
/// target the SDK's monitor is `Sendable` and an `AsyncSequence` (Element
/// `NWPath`), so `for await path in NWPathMonitor()` inside an actor task
/// auto-starts the monitor and ends iteration when the task is cancelled
/// (at the next emission at the latest).
struct NetworkPathSnapshot: Sendable, Equatable {
    enum Interface: String, Sendable, Hashable {
        case wifi, cellular, wiredEthernet, other, none
    }

    let isSatisfied: Bool
    let interface: Interface
    /// "en0" / "pdp_ip0" — included in the link identity so a same-type
    /// interface swap still reads as a handoff.
    let interfaceName: String
    let isExpensive: Bool
    let isConstrained: Bool        // Low Data Mode
    let isUltraConstrained: Bool   // iOS 26
    let linkQualityIsMinimal: Bool // iOS 26, reduced to Bool for cheap Equatable

    init(_ path: NWPath) {
        isSatisfied = path.status == .satisfied
        if path.usesInterfaceType(.wifi) {
            interface = .wifi
        } else if path.usesInterfaceType(.cellular) {
            interface = .cellular
        } else if path.usesInterfaceType(.wiredEthernet) {
            interface = .wiredEthernet
        } else if path.status == .satisfied {
            interface = .other
        } else {
            interface = .none
        }
        interfaceName = path.availableInterfaces.first?.name ?? ""
        isExpensive = path.isExpensive
        isConstrained = path.isConstrained
        isUltraConstrained = path.isUltraConstrained
        linkQualityIsMinimal = path.linkQuality == .minimal
    }

    /// What "a different link" means for reconnect purposes.
    var linkIdentity: String { "\(interface.rawValue)/\(interfaceName)" }

    /// Per-path video bitrate ceiling policy. Cellular caps the max so a 3 Mbps
    /// Wi-Fi target is never re-attempted verbatim on a weak cell; Low Data
    /// Mode and iOS 26 link-quality signals cap harder. Numbers are policy,
    /// tunable on device.
    func videoBitRateCeiling(configuredMaximum maximum: Int) -> Int {
        guard isSatisfied else { return maximum }
        var ceiling = maximum
        if interface == .cellular || isExpensive { ceiling = min(ceiling, 2_500_000) }
        if isConstrained { ceiling = min(ceiling, 1_200_000) }
        if isUltraConstrained { ceiling = min(ceiling, 800_000) }
        if linkQualityIsMinimal { ceiling = Swift.max(300_000, ceiling / 2) }
        return ceiling
    }
}
