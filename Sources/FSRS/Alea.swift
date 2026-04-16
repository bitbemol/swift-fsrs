import Foundation

/// Alea pseudo-random number generator by Johannes Baagøe.
///
/// Seeded by a string, produces deterministic `[0, 1)` doubles.
/// Ported from `ts-fsrs/src/fsrs/alea.ts` (which in turn is a port of
/// David Bau's JavaScript Alea) for byte-for-byte fuzz parity with ts-fsrs.
///
/// The algorithm uses three IEEE-754 doubles `s0`, `s1`, `s2` and an
/// integer carry `c`. Each call advances the state via:
/// ```
/// t = 2091639 * s0 + c * 2^-32
/// s0 = s1
/// s1 = s2
/// c  = floor(t)      // signed-32-bit truncation in JS (`t | 0`)
/// s2 = t - c         // fractional part in [0, 1)
/// return s2
/// ```
///
/// Seed mixing uses the `Mash` hash (shared state across mashes, as in JS)
/// to derive the initial `s0`, `s1`, `s2` from three space characters and
/// three passes over the seed string.
///
/// - Note: Matches ts-fsrs test vectors from `__tests__/alea.test.ts`.
///   The JS idiom `n >>> 0` is reproduced with `UInt32(truncatingIfNeeded:)`
///   and `t | 0` with `Int32(truncatingIfNeeded:)` cast back to `Double`.
struct Alea: Sendable {
    private var s0: Double
    private var s1: Double
    private var s2: Double
    private var c: Double

    /// Creates a seeded generator.
    ///
    /// - Parameter seed: Any string. An empty string falls back to
    ///   `Date().timeIntervalSince1970` so behaviour is randomish rather
    ///   than fixed. Callers that want determinism must pass a non-empty
    ///   seed.
    init(seed: String) {
        var mash = Mash()
        // Constructor order in ts-fsrs: c=1; then three mash(' ') calls
        // drain the initial Mash state, so each fresh Alea starts from
        // the same (s0, s1, s2) triple before the seed is mixed in.
        c = 1.0
        s0 = mash.next(" ")
        s1 = mash.next(" ")
        s2 = mash.next(" ")

        // Empty seed -> fall back to wall-clock time. ts-fsrs uses
        // `Date.now()` (integer ms); we use fractional seconds. The exact
        // value doesn't matter since the point is just "different each run".
        let seedStr = seed.isEmpty ? String(Date().timeIntervalSince1970) : seed

        s0 -= mash.next(seedStr)
        if s0 < 0 { s0 += 1 }
        s1 -= mash.next(seedStr)
        if s1 < 0 { s1 += 1 }
        s2 -= mash.next(seedStr)
        if s2 < 0 { s2 += 1 }
    }

    /// Advances the state and returns the next `[0, 1)` sample.
    mutating func next() -> Double {
        // 2.3283064365386963e-10 == 2^-32
        let t = 2_091_639.0 * s0 + c * 2.3283064365386963e-10
        s0 = s1
        s1 = s2
        // `t | 0` in JS is ToInt32: truncate toward zero modulo 2^32.
        // For our domain t is non-negative and small, so this is floor,
        // but we preserve the ToInt32 semantics for faithfulness.
        c = Double(Int32(truncatingIfNeeded: Int64(t)))
        s2 = t - c
        return s2
    }

    /// Advances the state and returns the next sample as a signed 32-bit
    /// integer in `[-2^31, 2^31)` (mirrors ts-fsrs `prng.int32`).
    mutating func int32() -> Int32 {
        // 0x100000000 == 2^32. Multiply a [0,1) double by 2^32 to get a
        // uniform [0, 2^32) double, then `| 0` to reinterpret as signed
        // 32-bit with wraparound.
        Int32(truncatingIfNeeded: Int64(next() * 4_294_967_296.0))
    }
}

/// Byte-mixing hash used by ``Alea`` to derive the initial state from a
/// seed string. Ported from ts-fsrs `Mash` closure.
///
/// Each `next(_:)` call folds `data`'s UTF-16 code units into an internal
/// 32-bit accumulator `n` and returns `(n >>> 0) * 2^-32` — a deterministic
/// `[0, 1)` double. Crucially, `n` persists across calls, so successive
/// mashes (three space characters, then three seed passes in ``Alea.init``)
/// produce different outputs for the same input.
///
/// - Important: The initial value of `n` is the JavaScript unsigned constant
///   `0xefc8249d`; ignore your intuition that Swift would overflow — Double
///   can hold that exactly. The bit-twiddling idioms (`n >>> 0`, `h >>> 0`)
///   are simulated by normalising through `UInt32(truncatingIfNeeded:)`.
struct Mash {
    private var n: Double = Double(UInt32(0xefc8_249d))

    /// Folds the UTF-16 code units of `data` into the accumulator and
    /// returns the derived `[0, 1)` value.
    ///
    /// - Note: ts-fsrs iterates `data.charCodeAt(i)`, i.e. UTF-16 code
    ///   units. Swift's `String.utf16` gives the same sequence, so seeds
    ///   containing non-BMP characters hash identically across both
    ///   implementations.
    mutating func next(_ data: String) -> Double {
        for code in data.utf16 {
            n += Double(code)
            var h = 0.02519603282416938 * n
            // `n = h >>> 0` — clamp to unsigned 32-bit, store as Double.
            n = Double(UInt32(truncatingIfNeeded: Int64(h)))
            h -= n
            h *= n
            // Repeat the `>>> 0` clamp for h's integer half.
            n = Double(UInt32(truncatingIfNeeded: Int64(h)))
            h -= n
            // 0x100000000 == 2^32.
            n += h * 4_294_967_296.0
        }
        // Final clamp + scale by 2^-32.
        return Double(UInt32(truncatingIfNeeded: Int64(n))) * 2.3283064365386963e-10
    }
}
