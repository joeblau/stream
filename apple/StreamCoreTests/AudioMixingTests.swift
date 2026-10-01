import Testing
@testable import StreamCore

/// A01 (issue #82): the gain ramps and summing math behind the routing buses.
@Suite("AudioMixing")
struct AudioMixingTests {
    @Test func gainRampEasesToTargetOverExactFrameCount() {
        var ramp = ChannelGainRamp(gain: 1)
        ramp.setTarget(0, rampFrames: 4)
        let gains = (0..<4).map { _ in ramp.advance() }
        #expect(gains == [0.75, 0.5, 0.25, 0])
        #expect(ramp.current == 0)
        #expect(ramp.target == 0)
        // Settled: the ramp holds the target without overshoot.
        #expect(ramp.advance() == 0)
    }

    @Test func zeroFrameRampAppliesImmediately() {
        var ramp = ChannelGainRamp(gain: 1)
        ramp.setTarget(0.25, rampFrames: 0)
        #expect(ramp.advance() == 0.25)
    }

    @Test func negativeGainTargetsClampToZero() {
        var ramp = ChannelGainRamp(gain: 1)
        ramp.setTarget(-2, rampFrames: 0)
        #expect(ramp.target == 0)
    }

    @Test func interruptedRampContinuesFromCurrentValue() {
        var ramp = ChannelGainRamp(gain: 0)
        ramp.setTarget(1, rampFrames: 10)
        _ = (0..<5).map { _ in ramp.advance() }   // halfway (0.5)
        ramp.setTarget(0, rampFrames: 5)          // re-target mid-ramp
        let gains = (0..<5).map { _ in ramp.advance() }
        #expect(gains.last == 0)
        #expect(gains.first! > 0 && gains.first! < 0.6)
    }

    @Test func accumulateMixesTwoChannelsWithIndependentGains() {
        let frames = 2
        var program = [Float](repeating: 0, count: frames * 2)
        var aux = [Float](repeating: 0, count: frames * 2)
        var full = ChannelGainRamp(gain: 1)
        var half = ChannelGainRamp(gain: 0.5)
        var silent = ChannelGainRamp(gain: 0)
        AudioMixerCore.accumulate(source: [1, 1, 1, 1], frameCount: frames,
                                  gain: &full, auxGain: &silent,
                                  program: &program, aux: &aux)
        AudioMixerCore.accumulate(source: [0.5, -0.5, 0.5, -0.5], frameCount: frames,
                                  gain: &half, auxGain: &full,
                                  program: &program, aux: &aux)
        // Program: 1*1 + 0.5*0.5 = 1.25 / 1*1 + (-0.5)*0.5 = 0.75 per frame.
        #expect(program == [1.25, 0.75, 1.25, 0.75])
        // Aux: channel 1 sends 0, channel 2 sends at unity.
        #expect(aux == [0.5, -0.5, 0.5, -0.5])
    }

    @Test func muteRemovesChannelFromProgramButKeepsAuxSend() {
        var program = [Float](repeating: 0, count: 2)
        var aux = [Float](repeating: 0, count: 2)
        var muted = ChannelGainRamp(gain: 0)
        var unity = ChannelGainRamp(gain: 1)
        AudioMixerCore.accumulate(source: [0.8, 0.8], frameCount: 1,
                                  gain: &muted, auxGain: &unity,
                                  program: &program, aux: &aux)
        #expect(program == [0, 0])
        #expect(aux == [0.8, 0.8])
    }

    @Test func busGainAndClampCeilTheSum() {
        var samples: [Float] = [1.6, -1.6, 0.5, -0.5]
        AudioMixerCore.applyBusGainAndClamp(&samples, gain: 1)
        #expect(samples == [1, -1, 0.5, -0.5])
        var gained: [Float] = [0.4, -0.4]
        AudioMixerCore.applyBusGainAndClamp(&gained, gain: 2)
        #expect(gained == [0.8, -0.8])
    }

    @Test func busesEnumerateTheA01RoutingSurface() {
        #expect(Set(AudioBus.allCases) == [.program, .monitor, .aux])
    }
}
