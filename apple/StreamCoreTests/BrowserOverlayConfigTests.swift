import Foundation
import Testing
@testable import StreamCore

/// G07 (issue #114): the normalization/validation contract of the browser
/// overlay configuration — the fail-closed URL rules, the measured cadence
/// ceiling, and the audio-route capability pins.
@Suite("G07 browser overlay config")
struct BrowserOverlayConfigTests {
    @Test("Defaults: muted audio, click-through, 30 fps, 720p raster")
    func defaults() {
        let config = BrowserOverlayConfiguration()
        #expect(config.urlString == nil)
        #expect(config.targetFPS == 30)
        #expect(config.pixelWidth == 1280)
        #expect(config.pixelHeight == 720)
        #expect(config.allowsInteraction == false)
        #expect(config.audioRoute == .muted)
    }

    @Test("Normalization clamps fps and pixel size into the supported window")
    func clamps() {
        let tooHot = BrowserOverlayConfiguration(targetFPS: 240,
                                                 pixelWidth: 8,
                                                 pixelHeight: 16_000).normalized()
        #expect(tooHot.targetFPS == 60)
        #expect(tooHot.pixelWidth == 16)
        #expect(tooHot.pixelHeight == 3840)

        let tooCold = BrowserOverlayConfiguration(targetFPS: 0,
                                                  pixelWidth: 640,
                                                  pixelHeight: 360).normalized()
        #expect(tooCold.targetFPS == 1)
        #expect(tooCold.pixelWidth == 640)
        #expect(tooCold.pixelHeight == 360)
    }

    @Test("http/https/file widget URLs are accepted")
    func supportedSchemes() {
        #expect(BrowserOverlayConfiguration.isSupportedWidgetURLString("https://streamlabs.com/alert-box"))
        #expect(BrowserOverlayConfiguration.isSupportedWidgetURLString("http://localhost:8080/widget"))
        #expect(BrowserOverlayConfiguration.isSupportedWidgetURLString("file:///tmp/fixture.html"))
        let config = BrowserOverlayConfiguration(urlString: "https://example.com/widget").normalized()
        #expect(config.urlString == "https://example.com/widget")
        #expect(config.widgetURL?.host() == "example.com")
    }

    @Test("Unsupported schemes and malformed strings fail closed to nil")
    func rejectedSchemes() {
        for bad in ["javascript:alert(1)",
                    "data:text/html,<h1>x</h1>",
                    "ftp://example.com/widget",
                    "not a url",
                    ""] {
            #expect(!BrowserOverlayConfiguration.isSupportedWidgetURLString(bad))
            let config = BrowserOverlayConfiguration(urlString: bad).normalized()
            #expect(config.urlString == nil)
            #expect(config.widgetURL == nil)
        }
        // Scheme matching is case-insensitive.
        #expect(BrowserOverlayConfiguration.isSupportedWidgetURLString("HTTPS://EXAMPLE.COM/W"))
    }

    @Test("Codable round-trip preserves every field")
    func codableRoundTrip() throws {
        let config = BrowserOverlayConfiguration(urlString: "https://example.com/alert",
                                                 targetFPS: 24,
                                                 pixelWidth: 1920,
                                                 pixelHeight: 1080,
                                                 allowsInteraction: true,
                                                 audioRoute: .helperApp).normalized()
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(BrowserOverlayConfiguration.self, from: data)
        #expect(decoded == config)
    }

    @Test("Only the helper-app route promises an independent mix channel")
    func audioRouteCapabilities() {
        #expect(BrowserWidgetAudioRoute.muted.hasIndependentMixChannel == false)
        #expect(BrowserWidgetAudioRoute.systemMix.hasIndependentMixChannel == false)
        #expect(BrowserWidgetAudioRoute.helperApp.hasIndependentMixChannel == true)
        #expect(BrowserWidgetAudioRoute.allCases.count == 3)
    }
}
