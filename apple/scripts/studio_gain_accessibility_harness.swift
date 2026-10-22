import Foundation

@main
enum StudioGainAccessibilityHarness {
    static func main() {
        for (gain, expected) in [(0.0, "0 percent"), (0.5, "50 percent"),
                                 (1.0, "100 percent"), (2.0, "200 percent"),
                                 (-0.5, "-50 percent")] {
            precondition(StudioGainAccessibility.value(gain) == expected)
        }
        precondition(StudioGainAccessibility.value(1e20) == "1e+22 percent")
        precondition(StudioGainAccessibility.value(-1e20) == "-1e+22 percent")
        for gain in [Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude] {
            let value = StudioGainAccessibility.value(gain)
            precondition(value.hasSuffix(" times unity gain"))
            precondition(value.contains("e+308"))
            precondition(!value.contains("inf") && !value.contains("nan"))
            precondition(value.count < 80)
        }
        for gain in [Double.nan, Double.infinity, -Double.infinity] {
            precondition(StudioGainAccessibility.value(gain) == "Volume unavailable")
        }
        print("PASS: shipping gain formatter; normal, negative, huge finite, scaling overflow and nonfinite values")
    }
}
