import Foundation

/// Adds controlled randomness to scheduled intervals.
///
/// When enabled, intervals are fuzzed within a range that grows with the
/// interval length. This prevents cards with similar histories from
/// clustering on the same review day.
///
/// The fuzz range is proportional to the interval:
/// - Intervals 2.5–7 days: ±15% of the excess
/// - Intervals 7–20 days: ±10% of the excess
/// - Intervals 20+ days: ±5% of the excess
///
/// Randomness is provided by a seeded ``Alea`` PRNG so callers passing
/// a stable seed (derived from card state) get deterministic, repeatable
/// output — matching ts-fsrs' `apply_fuzz` behaviour.
enum IntervalFuzzer {

    /// Applies deterministic fuzz to a computed interval.
    ///
    /// - Parameters:
    ///   - interval: The original interval in days.
    ///   - elapsedDays: Days since the last review (used as a minimum bound).
    ///   - maximumInterval: Hard cap on the fuzzed result.
    ///   - seed: String seed for the ``Alea`` PRNG. Pass a stable value
    ///     derived from card state (review time, reps, D×S) for
    ///     deterministic output.
    /// - Returns: A fuzzed interval within `[minIvl, maxIvl]`, or the
    ///   original interval if it's too short to fuzz (< 3 days).
    static func fuzz(
        interval: Int,
        elapsedDays: Int,
        maximumInterval: Int,
        seed: String
    ) -> Int {
        guard interval >= 3 else { return interval }

        let i = Double(interval)

        // Compute fuzz range — grows with interval length.
        var delta = 1.0
        delta += 0.15 * max(min(i, 7.0) - 2.5, 0)
        delta += 0.10 * max(min(i, 20.0) - 7.0, 0)
        delta += 0.05 * max(i - 20.0, 0)

        var minIvl = max(2, Int(round(i - delta)))
        let maxIvl = min(Int(round(i + delta)), maximumInterval)

        // Ensure fuzzed interval advances beyond the last review.
        if interval > elapsedDays {
            minIvl = max(minIvl, elapsedDays + 1)
        }
        minIvl = min(minIvl, maxIvl)

        // Match ts-fsrs `apply_fuzz`: floor(fuzz * (max - min + 1) + min).
        // Note: FLOOR, not round — critical for byte-for-byte parity.
        var prng = Alea(seed: seed)
        let fuzzFactor = prng.next()
        let range = Double(maxIvl - minIvl + 1)
        return Int((fuzzFactor * range + Double(minIvl)).rounded(.down))
    }
}
