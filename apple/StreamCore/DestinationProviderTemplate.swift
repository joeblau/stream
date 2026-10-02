import Foundation

/// Manual setup guidance, not a provider login or a capability grant. Links and
/// limitations are dated; an operator must obtain access in the provider UI.
public enum DestinationProviderTemplate: String, CaseIterable, Codable, Sendable, Identifiable {
    case instagram, amazonLive, x, tiktok, restream, switchboard, oneStream
    public var id: String { rawValue }
    public static let reviewedOn = "2026-10-02"
    public var name: String {
        switch self {
        case .instagram: return "Instagram Live Producer"
        case .amazonLive: return "Amazon Live Creator"
        case .x: return "X Media Studio Producer"
        case .tiktok: return "TikTok LIVE (if ingest granted)"
        case .restream: return "Restream relay"
        case .switchboard: return "Switchboard relay"
        case .oneStream: return "OneStream Live relay"
        }
    }
    public var isRelay: Bool { [.restream, .switchboard, .oneStream].contains(self) }
    public var transports: [StreamProtocol] {
        switch self {
        case .restream: return [.rtmps, .rtmp, .srt]
        case .switchboard: return [.rtmps, .rtmp, .srt]
        case .oneStream: return [.rtmps, .rtmp, .srt, .whip]
        case .amazonLive: return [.rtmp]
        case .instagram, .x, .tiktok: return [.rtmps, .rtmp]
        }
    }
    public var accountRequirement: String {
        switch self {
        case .instagram: return "Use an account that actually exposes Live Producer on instagram.com. Confirm today's account type and LIVE eligibility there; the archived official setup guide does not verify current access rules."
        case .amazonLive: return "Use an approved Amazon Live Creator account and verify your role and market in Amazon's Creator Hub. Amazon Ads lists registered brand owners in supported countries; Creator-app eligibility must be checked separately. Amazon IVS is a separate service."
        case .x: return "X says Media Studio access is for verified subscribers. Sign in, create a Producer source and broadcast, and use the source's own credentials."
        case .tiktok: return "TikTok requires age 18+ and LIVE eligibility that varies by region. Mobile LIVE access does not prove external-encoder access; use this guide only if TikTok explicitly grants your account an ingest URL and key."
        case .restream: return "Create an Encoder | RTMP stream and authorize downstream channels in Restream. RTMPS is available on all plans; SRT requires Business or custom Enterprise. Verify current entitlements there."
        case .switchboard: return "Use a Switchboard encoder workflow with authorized destinations. SRT requires the SBL Ingest workflow; migrate its provider in Switchboard if the SRT option is absent."
        case .oneStream: return "Use a OneStream account with RTMP Encoder access and authorized destinations. Check each downstream privacy setting; the documented default is public."
        }
    }
    public var keyLifecycle: String {
        switch self {
        case .instagram: return "The official archived guide says the key changes each Live Producer use. Copy a fresh key for each session; no fixed expiry duration is verified."
        case .amazonLive: return "Copy the current event's URL/key from External camera in the Creator app. A fixed key expiry is not verified; recheck before each event."
        case .x: return "Producer sources can be reused. A fixed key expiry is not published in the reviewed guide; verify the source and key before starting."
        case .tiktok: return "Key lifetime and external-encoder access are not verified by the public LIVE help pages. Obtain current credentials directly from your authorized account each session."
        case .restream: return "The RTMP stream's key remains static until Reset. A new stream card has a different key. SRT setup is separate; follow its issued URL."
        case .switchboard: return "Each workflow has its own stream URL/key. Resetting requires updating the encoder. Fixed expiry is not established in the reviewed guide; recheck before starting."
        case .oneStream: return "OneStream offers permanent and unique event keys; both can be reset. Confirm the selected event, key mode and schedule in OneStream."
        }
    }
    public var orientationRequirement: String {
        switch self {
        case .instagram: return "Archived official guidance recommends 9:16, 720×1280 at 30 fps; landscape is allowed but can be cropped in the viewer. Compose the program for portrait framing when needed."
        case .amazonLive: return "The archived external-camera guide recommends landscape 1280×720 at 30 fps. Confirm current event settings in the Creator app."
        case .x: return "Official examples use landscape 720p at 30/60 fps or 1080p at 30 fps. This starting profile uses 720p30."
        case .tiktok: return "No universal orientation requirement is verified in the public help pages. Portrait 720p30 here is an editable starting point; follow the settings supplied to your account."
        default: return "Match the relay workflow and every downstream platform. This starts at landscape 720p30; a relay may crop or transcode. Stream does not configure downstream orientation."
        }
    }
    public var eventControl: String {
        switch self {
        case .instagram: return "Preview the feed, then start/end the event in Live Producer. The archived guide says to end there before stopping the encoder to avoid a frozen last frame."
        case .amazonLive: return "The external-camera guide requires the Creator app to set up, start and stop the event. Stream sends media only."
        case .x: return "Create and control the broadcast in Producer. A connected source does not establish that a public event is live."
        case .tiktok: return "Control the event in TikTok's authorized account UI. Stream cannot obtain keys, create events or bypass account restrictions."
        default: return "Check selected downstream channels and auto-start/privacy settings in the relay before starting. A healthy relay connection does not verify every downstream broadcast."
        }
    }
    public var evidenceNotice: String {
        switch self {
        case .instagram: return "Official setup guidance is archived (2022); current account eligibility and key expiry still require verification."
        case .amazonLive: return "Official external-camera setup PDF is archived (2020); current Creator-app access and expiry require verification."
        case .tiktok: return "Public official help verifies general LIVE eligibility only, not an external-encoder grant, key expiry or orientation."
        default: return "Reviewed official provider guidance; no authenticated test ingest was performed. Recheck your account before each broadcast."
        }
    }
    public var capabilityDisclosure: String {
        "Manual ingest only. Comments, viewer metrics, event scheduling and remote event state are unavailable in Stream for this guide because no authorized provider API is connected."
    }
    public var sources: [(title: String, url: URL)] {
        let entries: [(String, String)]
        switch self {
        case .instagram: entries = [("Official archived Live Producer guide", "https://about.instagram.com/pt-br/blog/tips-and-tricks/instagram-live-producer/")]
        case .amazonLive: entries = [("Amazon Ads account/market guidance", "https://advertising.amazon.com/solutions/products/amazon-live"), ("Official archived external-camera guide", "https://m.media-amazon.com/images/G/01/AZL/AL-GSG-V2-3.30.20._CB1585614654_.pdf"), ("Creator Hub: verify access", "https://www.amazon.com/live/creator")]
        case .x: entries = [("Media Studio access", "https://help.x.com/en/using-x/media-studio"), ("Producer ingest specifications", "https://help.x.com/en/using-x/how-to-use-live-producer")]
        case .tiktok: entries = [("Official LIVE eligibility", "https://support.tiktok.com/en/live-gifts-wallet/tiktok-live/what-is-tiktok-live"), ("Official LIVE age requirements", "https://support.tiktok.com/en/safety-hc/account-and-user-safety/age-requirements-for-tiktok-live")]
        case .restream: entries = [("Encoder setup and key lifecycle", "https://support.restream.io/en/articles/6505602-go-live-with-streaming-software"), ("RTMPS access", "https://support.restream.io/en/articles/8523770-encrypt-your-stream-with-rtmps"), ("SRT access/setup", "https://support.restream.io/en/articles/9943983-how-to-stream-to-restream-using-srt"), ("Relay encoder guidelines", "https://support.restream.io/en/articles/73108-best-settings-for-your-streaming-software")]
        case .switchboard: entries = [("Official workflow setup", "https://kb.switchboard.live/en/help/articles/4403118745623-switchboard-live-initial-setup"), ("SRT workflow eligibility/setup", "https://kb.switchboard.live/help/articles/3576285-how-to-connect-your-encoder-to-switchboard-via-srt-input"), ("Workflow key reset", "https://kb.switchboard.live/help/articles/360002278754-workflow-page")]
        case .oneStream: entries = [("Current ingest protocols", "https://support.onestream.live/hc/knowledgebase/articles/1787743693-what-live-streaming-protocols-are-supported"), ("RTMP Encoder setup", "https://helpdesk.onestream.live/en-us/category/external-rtmp-encoder-129xi8n/"), ("Key modes and privacy", "https://helpdesk.onestream.live/en-us/article/how-to-change-privacy-for-rtmp-encoder-live-streaming-1uy0ejq/")]
        }
        return entries.map { (title: $0.0, url: URL(string: $0.1)!) }
    }
    /// Empty credentials and disabled state are deliberate: a template cannot
    /// grant authorization or start a stream. Limits are editable starting points.
    public func makeDestination(transport: StreamProtocol? = nil) -> StreamDestination {
        let selected = transport.flatMap { transports.contains($0) ? $0 : nil } ?? transports[0]
        let portrait = self == .instagram || self == .tiktok
        let profile = OutputProfile(canvasWidth: portrait ? 720 : 1280, canvasHeight: portrait ? 1280 : 720, frameRate: 30)
        return StreamDestination(name: name, transport: selected, isEnabled: false, followsProgramProfile: false,
            outputProfile: profile, videoCodec: .h264, videoBitrate: self == .amazonLive ? 2_800_000 : (self == .x ? 9_000_000 : 4_000_000),
            audioBitrate: 128_000,
            ingestLimits: .init(source: .customOverride, maxWidth: 1920, maxHeight: 1080, maxFrameRate: 30,
                                codecs: [.h264], maxKeyframeSeconds: self == .x ? 3 : 2, maxAudioBitrate: 128_000),
            keyframeSeconds: self == .x ? 3 : 2, providerTemplateID: rawValue)
    }
    public var encoderCaveat: String {
        switch self {
        case .instagram, .restream: return "The reviewed guide recommends 44.1 kHz audio; Stream currently sends stereo 48 kHz audio. Verify acceptance with a test event. Templates do not certify encoder conformity."
        default: return "Starting limits are editable custom settings, not a verified ingest result. Test this account's event before a public broadcast."
        }
    }
    public func protocolSetup(_ transport: StreamProtocol) -> String {
        if transport == .whip {
            return "WHIP is experimental in Stream (H.264/Opus). Bearer-header authentication and a separate WHIP key are unsupported. Use this only if OneStream issues a complete HTTPS WHIP URL carrying its own authorization; otherwise choose RTMPS."
        }
        if transport == .srt {
            if self == .oneStream {
                return "Copy the SRT URL from OneStream's selected protocol and preserve its routing/authentication fields. If it supplies a separate key without a complete SRT route, verify the required stream ID with OneStream or choose RTMPS; Stream does not guess a key-to-stream-ID mapping."
            }
            return "Use the provider's full SRT caller URL, preserving stream ID/passphrase query values. Restream and Switchboard document leaving the separate stream key blank. Optional fields override matching URL values only when filled."
        }
        return "Copy the issued server URL and stream key separately. Match RTMP or RTMPS to its exact URL scheme. Stream does not fetch, refresh or extract credentials from a browser."
    }
}
