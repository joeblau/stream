import Foundation

/// Portable destination configuration. Connection details deliberately have no
/// Codable representation: a project can reference this ID but cannot export its secrets.
public struct StreamDestination: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var transport: StreamProtocol
    public var isEnabled: Bool
    /// All destinations consume the program canvas; a separate output profile
    /// may resize that canvas for an ingest without changing local recording.
    public var followsProgramProfile: Bool
    public var outputProfile: OutputProfile
    public var videoCodec: VideoCodec
    public var videoBitrate: Int
    public var audioBitrate: Int
    public var ingestLimits: DestinationIngestLimits?
    public var keyframeSeconds: Double?
    /// Optional guidance identity, never an account, event ID or ingest secret.
    /// A string tolerates templates introduced by a newer application version.
    public var providerTemplateID: String?
    public var providerBinding: ProviderDestinationBinding?

    public init(id: UUID = UUID(), name: String, transport: StreamProtocol = .rtmps,
                isEnabled: Bool = true, followsProgramProfile: Bool = true,
                outputProfile: OutputProfile = .default, videoCodec: VideoCodec = .h264,
                videoBitrate: Int = 4_000_000, audioBitrate: Int = 128_000, ingestLimits: DestinationIngestLimits? = nil, keyframeSeconds: Double? = nil,
                providerTemplateID: String? = nil, providerBinding: ProviderDestinationBinding? = nil) {
        self.id = id
        self.name = name
        self.transport = transport
        self.isEnabled = isEnabled
        self.followsProgramProfile = followsProgramProfile
        self.outputProfile = outputProfile
        self.videoCodec = videoCodec
        self.videoBitrate = videoBitrate
        self.audioBitrate = audioBitrate
        self.ingestLimits = ingestLimits
        self.keyframeSeconds = keyframeSeconds
        self.providerTemplateID = providerTemplateID
        self.providerBinding = providerBinding
    }

    public func duplicated() -> Self {
        var copy = self
        copy.id = UUID()
        copy.name += " Copy"
        // Duplicating configuration must never silently double public output.
        copy.isEnabled = false
        return copy
    }

    public func effectiveProfile(program: OutputProfile) -> OutputProfile {
        followsProgramProfile ? program : outputProfile
    }

    public var providerTemplate: DestinationProviderTemplate? {
        providerTemplateID.flatMap(DestinationProviderTemplate.init(rawValue:))
    }

    public var codecNotice: String? {
        if !transport.supports(videoCodec) {
            return "\(transport.displayName) does not support \(videoCodec.displayName). Choose H.264."
        }
        if transport == .whip {
            return "WHIP is experimental (H.264/Opus). Bearer-header authentication is not supported; use an endpoint that accepts its secret in the URL."
        }
        if (transport == .rtmp || transport == .rtmps) && videoCodec == .hevc {
            return "HEVC requires an enhanced-RTMP ingest. Traditional RTMP services require H.264."
        }
        return nil
    }
}

/// In-memory editing/publishing credentials; NEVER encode these into a project.
public struct DestinationCredentials: Equatable, Sendable {
    public var endpoint: String
    public var streamKey: String
    public var srtStreamID: String
    public var srtPassphrase: String

    public init(endpoint: String = "", streamKey: String = "",
                srtStreamID: String = "", srtPassphrase: String = "") {
        self.endpoint = endpoint
        self.streamKey = streamKey
        self.srtStreamID = srtStreamID
        self.srtPassphrase = srtPassphrase
    }

    /// Preserves provider-specific query items while updating explicit SRT fields.
    public func publishingURL(for transport: StreamProtocol) -> String {
        let endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard transport == .srt, var components = URLComponents(string: endpoint) else {
            return endpoint
        }
        var items = components.queryItems ?? []
        for (name, value) in [("streamid", srtStreamID), ("passphrase", srtPassphrase)] {
            guard !value.isEmpty else { continue }
            items.removeAll { $0.name.lowercased() == name }
            items.append(URLQueryItem(name: name, value: value))
        }
        components.queryItems = items.isEmpty ? nil : items
        return components.string ?? endpoint
    }
}

public enum DestinationValidator {
    /// Allows incomplete drafts, but rejects malformed fields before persistence.
    public static func errors(_ destination: StreamDestination,
                              credentials: DestinationCredentials) -> [String] {
        var errors: [String] = []
        if destination.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("Give this destination a name.")
        }
        if let error = SettingsValidator.serverURLError(credentials.endpoint, for: destination.transport) {
            errors.append(error)
        }
        if let error = SettingsValidator.streamKeyError(credentials.streamKey, for: destination.transport) {
            errors.append(error)
        }
        if let c = URLComponents(string: credentials.publishingURL(for: destination.transport)),
           !credentials.endpoint.isEmpty {
            if c.fragment != nil { errors.append("Remove the URL fragment; ingest URLs do not use fragments.") }
            if destination.transport == .srt {
                if c.port == nil { errors.append("SRT requires an explicit destination port.") }
                let items = c.queryItems ?? []
                let passphrase = items.first { $0.name.lowercased() == "passphrase" }?.value ?? ""
                if !passphrase.isEmpty && !(10...79).contains(passphrase.utf8.count) {
                    errors.append("An SRT passphrase must be 10–79 UTF-8 bytes.")
                }
                if let mode = items.first(where: { $0.name.lowercased() == "mode" })?.value,
                   mode.lowercased() != "caller" {
                    errors.append("Publishing supports SRT caller mode. Remove mode or choose mode=caller.")
                }
            }
            if destination.transport == .whip && c.path.isEmpty {
                errors.append("WHIP requires the provider's endpoint path.")
            }
        }
        if !(100_000...100_000_000).contains(destination.videoBitrate) {
            errors.append("Video bitrate must be 0.1–100 Mbps.")
        }
        if let seconds = destination.keyframeSeconds,
           !seconds.isFinite || seconds < 1 || seconds > 10 || seconds.rounded() != seconds {
            errors.append("Keyframe interval must be a whole number from 1–10 seconds.")
        }
        if !(16_000...512_000).contains(destination.audioBitrate) {
            errors.append("Audio bitrate must be 16–512 kbps.")
        }
        return errors
    }

    public static func startErrors(_ destination: StreamDestination,
                                   credentials: DestinationCredentials,
                                   program: OutputProfile,
                                   capabilities: OutputCapabilities = .current) -> [String] {
        var errors = errors(destination, credentials: credentials)
        if credentials.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("Enter the destination endpoint URL.")
        }
        if destination.transport.requiresKey && credentials.streamKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("Enter the stream key.")
        }
        if !destination.transport.supports(destination.videoCodec), let notice = destination.codecNotice {
            errors.append(notice)
        }
        let profile = destination.effectiveProfile(program: program)
        if !capabilities.hardwareTier.fits(width: profile.canvasWidth, height: profile.canvasHeight) {
            errors.append("This Mac's estimated hardware limit is \(capabilities.hardwareTier.displayName).")
        }
        if profile.frameRate > capabilities.hardwareMaxFrameRate {
            errors.append("This Mac's estimated hardware limit is \(capabilities.hardwareMaxFrameRate) fps.")
        }
        let limits = destination.ingestLimits ?? .conservative(for: destination.transport)
        errors += limits.errors(profile: profile, codec: destination.videoCodec,
                                keyframeSeconds: destination.keyframeSeconds ?? 2, audioBitrate: destination.audioBitrate)
        if let template = destination.providerTemplate, !template.transports.contains(destination.transport) {
            errors.append("This \(template.name) guide does not establish \(destination.transport.displayName) ingest support. Use its issued protocol or clear the guide for a custom destination.")
        }
        return errors
    }

    public static func settings(_ destination: StreamDestination, credentials: DestinationCredentials,
                                base: StreamSettings) -> StreamSettings {
        var settings = base
        settings.selectedProtocol = destination.transport
        settings.rtmpURL = credentials.publishingURL(for: destination.transport)
        settings.streamKey = credentials.streamKey
        settings.outputProfile = destination.effectiveProfile(program: base.outputProfile)
        settings.videoQuality = min(settings.outputProfile.canvasWidth, settings.outputProfile.canvasHeight)
        settings.frameRate = settings.outputProfile.frameRate
        settings.videoCodec = destination.videoCodec
        settings.videoBitrate = destination.videoBitrate
        settings.audioBitrate = destination.audioBitrate
        settings.destinationKeyframeSeconds = destination.keyframeSeconds
        return settings
    }
}
