import Foundation

/// A deterministic generator for the tests that measure a detector against a noise floor.
///
/// Those tests used `SystemRandomNumberGenerator`, which drew a different noise floor every
/// run and turned every threshold assertion into a coin flip. Sharpness scores in particular
/// depend on where the noise happens to peak, so a bound that holds on one run can fail on
/// the next for no reason at all — which is exactly what CI eventually caught.
///
/// SplitMix64. Each test makes its own instance, because the suite runs in parallel and a
/// shared one would interleave draws and go right back to being unpredictable.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64 = 0x5EED) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
