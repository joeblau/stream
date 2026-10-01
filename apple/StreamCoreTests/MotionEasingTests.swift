import Testing
import StreamCore

@Suite struct MotionEasingTests {
    @Test func endpointsAndFiniteBounds() {
        for easing in MotionEasing.allCases {
            #expect(easing.value(at: -1) == 0)
            #expect(easing.value(at: 0) == 0)
            #expect(easing.value(at: 1) == 1)
            #expect(easing.value(at: 2) == 1)
            #expect(easing.value(at: .nan) == 0)
            let values = (0...100).map { easing.value(at: Double($0) / 100) }
            #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
        }
    }
    @Test func easingHasExpectedShape() {
        #expect(MotionEasing.linear.value(at: 0.5) == 0.5)
        #expect(MotionEasing.easeIn.value(at: 0.5) == 0.125)
        #expect(MotionEasing.easeOut.value(at: 0.5) == 0.875)
        #expect(MotionEasing.easeInOut.value(at: 0.25) == 0.0625)
        #expect(MotionEasing.easeInOut.value(at: 0.75) == 0.9375)
    }
}
