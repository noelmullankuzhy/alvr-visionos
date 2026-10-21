// SOURCES:
import Foundation

@main enum Float16ToleranceTests {
    static func main() {
        // Device stores observed by GM: one binary16 value below nearest rounding.
        expect(withinFloat16ULP(2.798828125, 2.8), "2.8 device store is within one half ulp")
        expect(withinFloat16ULP(2.8984375, 2.9), "2.9 device store is within one half ulp")
        for expected: Float in [0, 0.15, 0.25, 0.5, 1, 1.9583334, 2, 2.8, 2.9, 4] {
            let rounded = Float(Float16(expected)), ulp = Float(Float16(expected).ulp)
            expect(withinFloat16ULP(rounded, expected), "nearest rounding accepted")
            expect(withinFloat16ULP(rounded - ulp, rounded), "one ulp below accepted")
            expect(withinFloat16ULP(rounded + ulp, rounded), "one ulp above accepted")
            expect(!withinFloat16ULP(rounded - 2 * ulp, rounded), "two ulps below rejected")
            expect(!withinFloat16ULP(rounded + 2 * ulp, rounded), "two ulps above rejected")
        }
        expect(!withinFloat16ULP(.nan, 1), "NaN readback rejected")
        expect(!withinFloat16ULP(.infinity, 1), "infinite readback rejected")
        expect(!withinFloat16ULP(1, .infinity), "invalid expected value rejected")
        finishTests("Float16Tolerance")
    }
}
