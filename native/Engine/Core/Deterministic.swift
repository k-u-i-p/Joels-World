import Foundation

/// A small, fast, seedable random source.
///
/// `Double.random(in:)` draws from the system generator, which means two runs of the same match
/// never play out the same way and a bug in a rally can never be reproduced. Everything in the
/// 3D tennis game — the serve placement, where the opponent aims, how much it mistimes a shot —
/// comes through here instead, seeded once per point from the score. Same score, same rally.
///
/// SplitMix64: the seeding generator behind xoshiro, chosen because it is eight lines, has no
/// bad seeds (zero included), and passes BigCrush on its own.
struct DeterministicRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &+ 0x9E3779B97F4A7C15
    }

    /// Re-seeds in place, so a caller can pin a fresh sequence to a new point without
    /// allocating a new generator.
    mutating func reseed(_ seed: UInt64) {
        state = seed &+ 0x9E3779B97F4A7C15
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    /// A double in `[0, 1)`, built from the top 53 bits so every value is exactly representable.
    mutating func unit() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    /// A double in `[-1, 1)`.
    mutating func signed() -> Double {
        unit() * 2 - 1
    }

    mutating func range(_ lower: Double, _ upper: Double) -> Double {
        lower + unit() * (upper - lower)
    }

    /// True with probability `p`.
    mutating func chance(_ p: Double) -> Bool {
        unit() < p
    }

    /// A bell-ish distribution centred on 0, roughly within ±`spread`. Three uniforms averaged —
    /// enough of a normal for aiming error, and it never produces an outlier that sends a shot
    /// into orbit.
    mutating func spread(_ spread: Double) -> Double {
        (signed() + signed() + signed()) / 3 * spread
    }
}
