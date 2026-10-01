import Testing
import StreamCore

/// Tests for the A09 duplicate capture/feedback route analysis: each scenario
/// builds the routing facts and checks the identified issue + its repair.
@Suite struct FeedbackRouteAnalyzerTests {

    @Test("Monitoring off means no electrical routes")
    func monitoringOffIsClear() {
        var input = FeedbackRouteInput()
        input.monitoringEnabled = false
        input.monitorOutputUID = "SpeakerUID"
        input.preferredInputUID = "SpeakerUID"
        #expect(FeedbackRouteAnalyzer.issues(for: input).isEmpty)
    }

    @Test("Monitor output == preferred input is flagged with the monitoring repair")
    func monitorIsPreferredInput() {
        var input = FeedbackRouteInput()
        input.monitoringEnabled = true
        input.monitorOutputUID = "USB DAC"
        input.preferredInputUID = "USB DAC"
        let issues = FeedbackRouteAnalyzer.issues(for: input)
        #expect(issues.count == 1)
        #expect(issues[0].kind == .monitorIsPreferredInput)
        #expect(issues[0].deviceUID == "USB DAC")
        #expect(issues[0].repair == .disableMonitoring)
        #expect(!issues[0].fix.isEmpty)
    }

    @Test("Monitor output == system default input is flagged when no preferred input is set")
    func monitorIsDefaultInput() {
        var input = FeedbackRouteInput()
        input.monitoringEnabled = true
        input.monitorOutputUID = "Built-in"
        input.defaultInputUID = "Built-in"
        input.preferredInputUID = nil
        let issues = FeedbackRouteAnalyzer.issues(for: input)
        #expect(issues.map(\.kind) == [.monitorIsDefaultInput])
        #expect(issues[0].repair == .disableMonitoring)
    }

    @Test("An explicit preferred input different from the monitor output clears the default-input route")
    func explicitPreferredInputClearsDefaultRoute() {
        var input = FeedbackRouteInput()
        input.monitoringEnabled = true
        input.monitorOutputUID = "Built-in"
        input.defaultInputUID = "Built-in"
        input.preferredInputUID = "USB Mic"
        #expect(FeedbackRouteAnalyzer.issues(for: input).isEmpty)
    }

    @Test("Monitor output == enabled additional input offers disabling that input")
    func monitorIsAdditionalInput() {
        var input = FeedbackRouteInput()
        input.monitoringEnabled = true
        input.monitorOutputUID = "Interface"
        input.preferredInputUID = "USB Mic"
        input.additionalEnabledInputUIDs = ["Interface", "Camera Mic"]
        let issues = FeedbackRouteAnalyzer.issues(for: input)
        #expect(issues.map(\.kind) == [.monitorIsAdditionalInput])
        #expect(issues[0].repair == .disableInput(deviceUID: "Interface"))
    }

    @Test("Safe routing produces no issues")
    func safeRoutingIsClear() {
        var input = FeedbackRouteInput()
        input.monitoringEnabled = true
        input.monitorOutputUID = "Headphones"
        input.defaultInputUID = "Built-in"
        input.preferredInputUID = "USB Mic"
        input.additionalEnabledInputUIDs = ["Camera Mic"]
        #expect(FeedbackRouteAnalyzer.issues(for: input).isEmpty)
    }

    @Test("A howling channel gets an acoustic repair even with no electrical route")
    func acousticHowl() {
        var input = FeedbackRouteInput()
        input.monitoringEnabled = true
        input.monitorOutputUID = "Headphones"
        input.preferredInputUID = "USB Mic"
        input.howlingChannelLabels = ["mic.default"]
        let issues = FeedbackRouteAnalyzer.issues(for: input)
        #expect(issues.count == 1)
        #expect(issues[0].kind == .acousticHowl)
        #expect(issues[0].affectedChannel == "mic.default")
        #expect(issues[0].repair == .lowerMonitor)
        #expect(issues[0].fix.contains("Monitor"))
    }

    @Test("Electrical and acoustic issues compose with stable identities")
    func composedIssues() {
        var input = FeedbackRouteInput()
        input.monitoringEnabled = true
        input.monitorOutputUID = "Interface"
        input.additionalEnabledInputUIDs = ["Interface"]
        input.howlingChannelLabels = ["mic.default"]
        let issues = FeedbackRouteAnalyzer.issues(for: input)
        #expect(issues.map(\.kind) == [.monitorIsAdditionalInput, .acousticHowl])
        #expect(Set(issues.map(\.id)).count == issues.count)
    }
}
