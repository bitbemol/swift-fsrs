import Foundation

/// Core FSRS v6 mathematical model.
///
/// Implements the 9 formulas that define the spaced repetition algorithm:
/// forgetting curve, initial/next stability, initial/next difficulty,
/// recall/forget/short-term stability, and interval calculation.
///
/// All methods are pure functions of the 21 trainable weights.
struct FSRSAlgorithm: Sendable {

    // MARK: - Constants

    static let sMin = 0.001
    static let sMax = 36500.0
    static let dMin = 1.0
    static let dMax = 10.0

    // MARK: - Rounding

    /// Rounds a Double to `decimals` fractional digits, matching ts-fsrs'
    /// `help.ts` `roundTo(num, decimals)`: `Math.round(num * 10^decimals) / 10^decimals`.
    ///
    /// `.toNearestOrAwayFromZero` matches JS `Math.round`'s half-to-+∞ rule
    /// within the FSRS domain, where all rounded values (stability > 0,
    /// difficulty ∈ [1,10], retrievability ∈ [0,1], factor > 0) are non-negative.
    @inlinable
    static func roundTo(_ value: Double, decimals: Int = 8) -> Double {
        let multiplier = pow(10.0, Double(decimals))
        return (value * multiplier).rounded(.toNearestOrAwayFromZero) / multiplier
    }

    // MARK: - Precomputed values

    let w: Weights
    let enableShortTerm: Bool
    let maximumInterval: Int

    /// Forgetting curve decay: `-w[20]`. Negative because the curve decreases.
    /// In FSRS v5 this was fixed at -0.5; v6 makes it trainable.
    let decay: Double

    /// Scaling factor that ensures R(S, S) = 0.9.
    /// Derived: `factor = exp(ln(0.9) / decay) - 1`
    let factor: Double

    /// Precomputed multiplier for converting stability to interval.
    /// `intervalModifier = (retention^(1/decay) - 1) / factor`
    ///
    /// When `requestRetention = 0.9`, this equals 1.0 (since S is defined
    /// as the interval where R = 90%).
    let intervalModifier: Double

    init(parameters: Parameters) {
        self.w = parameters.weights
        self.enableShortTerm = parameters.enableShortTerm
        self.maximumInterval = parameters.maximumInterval

        // Mirrors ts-fsrs `computeDecayFactor` (algorithm.ts:22-23): factor is
        // rounded, decay is not (decay is passed raw from `-w[20]`).
        let decay = -w[20]
        self.decay = decay
        self.factor = Self.roundTo(exp(log(0.9) / decay) - 1.0)
        // ts-fsrs `calculate_interval_modifier` (algorithm.ts:92) rounds the
        // modifier to 8 decimals after computing the ratio with the already
        // rounded factor.
        self.intervalModifier = Self.roundTo(
            (pow(parameters.requestRetention, 1.0 / decay) - 1.0) / self.factor
        )
    }

    // MARK: - Forgetting Curve

    /// Probability of recall after `t` days with stability `s`.
    ///
    /// `R(t, S) = (1 + factor × t / S) ^ decay`
    ///
    /// Returns 1.0 for t=0 (just reviewed), 0.9 for t=S (by construction),
    /// and decays toward 0 as t → ∞.
    ///
    /// Matches ts-fsrs `forgetting_curve` (algorithm.ts:44-51): the returned
    /// probability is rounded to 8 decimals.
    func forgettingCurve(elapsedDays t: Double, stability s: Double) -> Double {
        guard s >= Self.sMin else { return 0 }
        return Self.roundTo(pow(1.0 + factor * t / s, decay))
    }

    // MARK: - Initial State (first review of a new card)

    /// Initial stability for a new card based on the first rating.
    ///
    /// `S₀(G) = max(w[G-1], 0.1)`
    func initialStability(rating: Rating) -> Double {
        max(w[rating.rawValue - 1], 0.1)
    }

    /// Initial difficulty for a new card based on the first rating.
    ///
    /// `D₀(G) = w[4] - exp((G-1) × w[5]) + 1`, clamped to [1, 10].
    ///
    /// Again gives the highest difficulty (≈ w[4]), Easy the lowest (clamped to 1).
    func initialDifficulty(rating: Rating) -> Double {
        clampD(rawInitialDifficulty(rating: rating))
    }

    /// Raw (unclamped but 8-decimal rounded) initial difficulty used for the
    /// mean-reversion target in ``nextDifficulty(current:rating:)``.
    ///
    /// ts-fsrs's `init_difficulty` returns `roundTo(d, 8)` without clamping
    /// (algorithm.ts:169-173) and the clamp only happens at the `next_state`
    /// call site. `nextDifficulty` uses this rounded value so the
    /// mean-reversion target matches ts-fsrs exactly; with default weights
    /// and rating=Easy, this is ≈ -4.77163070.
    private func rawInitialDifficulty(rating: Rating) -> Double {
        let g = Double(rating.rawValue)
        let d = w[4] - exp((g - 1.0) * w[5]) + 1.0
        return Self.roundTo(d)
    }

    // MARK: - Next Difficulty

    /// Updated difficulty after a review.
    ///
    /// Uses linear damping (changes are smaller when D is near 10) and
    /// mean reversion (gentle pull toward D₀(Easy) via w[7]).
    ///
    /// ```
    /// Δd = -w[6] × (G - 3)
    /// D' = w[7] × D₀(4) + (1 - w[7]) × (D + Δd × (10 - D) / 9)
    /// ```
    ///
    /// Rounds each intermediate the same way ts-fsrs does
    /// (`linear_damping` at algorithm.ts:210, `mean_reversion` at 241).
    /// The final clamp is NOT rounded -- it operates on an already-rounded
    /// value, matching ts-fsrs `next_difficulty` (algorithm.ts:222-230).
    func nextDifficulty(current d: Double, rating: Rating) -> Double {
        let g = Double(rating.rawValue)
        let deltaD = -w[6] * (g - 3.0)
        // Mirrors ts-fsrs `linear_damping` return.
        let linearDamping = Self.roundTo(deltaD * (10.0 - d) / 9.0)
        // `next_d = d + linear_damping(...)` in ts-fsrs is NOT rounded here --
        // only the components are rounded (linear_damping above, and the
        // mean-reversion result below).
        let nextD = d + linearDamping
        // Mean reversion toward the *unclamped* (but rounded) D₀(Easy).
        // ts-fsrs keeps the raw (typically negative) value as the reversion
        // target -- clamping would shift the equilibrium point and diverge
        // from the reference scheduler. `rawInitialDifficulty` already rounds
        // to 8 decimals to match ts-fsrs `init_difficulty`.
        let d0EasyRaw = rawInitialDifficulty(rating: .easy)
        // Mirrors ts-fsrs `mean_reversion` return (algorithm.ts:241).
        let reverted = Self.roundTo(w[7] * d0EasyRaw + (1.0 - w[7]) * nextD)
        return clampD(reverted)
    }

    // MARK: - Stability After Successful Recall

    /// Stability after the user successfully recalled the card (Hard/Good/Easy, t ≥ 1).
    ///
    /// ```
    /// S'ᵣ = S × (1 + e^w[8] × (11 - D) × S^(-w[9]) × (e^(w[10]×(1-R)) - 1) × penalty × bonus)
    /// ```
    ///
    /// Key properties:
    /// - Higher D → less stability gain (harder cards grow slower)
    /// - Higher S → less relative gain (diminishing returns)
    /// - Lower R → more gain (spacing effect: reviewing near forgetting is more effective)
    ///
    /// Returns `roundTo(clamp(..., S_MIN, S_MAX), 8)` to match ts-fsrs
    /// `next_recall_stability` (algorithm.ts:257-271).
    func nextRecallStability(d: Double, s: Double, r: Double, rating: Rating) -> Double {
        let hardPenalty = rating == .hard ? w[15] : 1.0
        let easyBonus = rating == .easy ? w[16] : 1.0

        let result = s * (1.0 + exp(w[8])
            * (11.0 - d)
            * pow(s, -w[9])
            * (exp(w[10] * (1.0 - r)) - 1.0)
            * hardPenalty
            * easyBonus)

        return Self.roundTo(clampS(result))
    }

    // MARK: - Stability After Lapse (Forgetting)

    /// Stability after the user forgot the card (Again, t ≥ 1).
    ///
    /// ```
    /// S'f = w[11] × D^(-w[12]) × ((S+1)^w[13] - 1) × e^(w[14]×(1-R))
    /// ```
    ///
    /// The result is typically much smaller than the pre-lapse S, reflecting
    /// the memory reset that occurs when a card is forgotten.
    ///
    /// Returns `roundTo(clamp(..., S_MIN, S_MAX), 8)` to match ts-fsrs
    /// `next_forget_stability` (algorithm.ts:284-297).
    func nextForgetStability(d: Double, s: Double, r: Double) -> Double {
        let sf = w[11]
            * pow(d, -w[12])
            * (pow(s + 1.0, w[13]) - 1.0)
            * exp(w[14] * (1.0 - r))

        return Self.roundTo(clampS(sf))
    }

    // MARK: - Stability After Same-Day Review

    /// Stability after a same-day review (t = 0, short-term mode enabled).
    ///
    /// v6 adds the `S^(-w[19])` dampening term so that cards with low stability
    /// gain more from same-day reviews than cards with high stability, preventing
    /// unbounded stability growth from repeated same-day reviews.
    ///
    /// ```
    /// sinc = S^(-w[19]) × e^(w[17] × (G - 3 + w[18]))
    /// if G ≥ Hard: sinc = max(sinc, 1.0)    // stability can only grow
    /// S'ₛ = S × sinc
    /// ```
    ///
    /// Returns `roundTo(clamp(s * maskedSinc, S_MIN, S_MAX), 8)` to match
    /// ts-fsrs `next_short_term_stability` (algorithm.ts:305-311).
    func nextShortTermStability(s: Double, rating: Rating) -> Double {
        let g = Double(rating.rawValue)
        var sinc = pow(s, -w[19]) * exp(w[17] * (g - 3.0 + w[18]))

        // For Hard/Good/Easy, stability can only increase
        if rating >= .hard {
            sinc = max(sinc, 1.0)
        }

        return Self.roundTo(clampS(s * sinc))
    }

    // MARK: - Interval Calculation

    /// Converts stability to a review interval in whole days.
    ///
    /// `I(S) = round(S × intervalModifier)`, clamped to [1, maximumInterval].
    func nextInterval(stability s: Double) -> Int {
        let interval = s * intervalModifier
        // Use .toNearestOrAwayFromZero to match JavaScript's Math.round()
        // (Swift's default round() uses banker's rounding which differs at .5)
        return Int(min(max(interval.rounded(.toNearestOrAwayFromZero), 1.0), Double(maximumInterval)))
    }

    // MARK: - State Dispatch

    /// Computes the next (stability, difficulty) pair.
    ///
    /// Dispatches to the correct formula based on current state and elapsed time:
    /// - **New card** (s=0, d=0): ``initialStability(rating:)`` / ``initialDifficulty(rating:)``
    /// - **Same-day** (t == 0, short-term enabled): ``nextShortTermStability(s:rating:)``
    /// - **Lapse** (Again, t ≥ 1 day): ``nextForgetStability(d:s:r:)`` with post-lapse constraint
    /// - **Recall** (Hard/Good/Easy, t ≥ 1 day): ``nextRecallStability(d:s:r:rating:)``
    ///
    /// - Parameter t: Elapsed UTC calendar days since the last review (see
    ///   ``Card/elapsedDays(now:)``). Must be ≥ 0.
    func nextState(
        stability s: Double,
        difficulty d: Double,
        elapsedDays t: Int,
        rating: Rating
    ) -> (stability: Double, difficulty: Double) {
        // New card — no prior state
        if s < Self.sMin && d < Self.dMin {
            return (
                stability: initialStability(rating: rating),
                difficulty: initialDifficulty(rating: rating)
            )
        }

        // The forgetting curve is defined on real-valued t; cast once at the
        // boundary. The schedulers always pass whole calendar-day counts.
        let r = forgettingCurve(elapsedDays: Double(t), stability: s)
        let newD = nextDifficulty(current: d, rating: rating)
        let newS: Double

        if t == 0 && enableShortTerm {
            // Same-day review — use short-term stability formula
            newS = nextShortTermStability(s: s, rating: rating)
        } else if rating == .again {
            // Lapse — use forget formula with post-lapse constraint
            let sf = nextForgetStability(d: d, s: s, r: r)
            let postLapseFloor: Double
            if enableShortTerm {
                // Prevent relearning steps from inflating stability above pre-lapse S.
                // S / exp(w[17] * w[18]) is the minimum post-lapse S such that
                // subsequent short-term steps can't push it above the original S.
                postLapseFloor = s / exp(w[17] * w[18])
            } else {
                postLapseFloor = s
            }
            // ts-fsrs rounds the floor BEFORE clamping against s_after_fail
            // (algorithm.ts:376). Matching that order matters because the clamp
            // may then return either the (rounded) floor or the (rounded) sf.
            let roundedFloor = Self.roundTo(postLapseFloor)
            // clamp(roundedFloor, sMin, sf): floor can't exceed the forget formula result.
            newS = min(max(roundedFloor, Self.sMin), sf)
        } else {
            // Successful recall
            newS = nextRecallStability(d: d, s: s, r: r, rating: rating)
        }

        return (stability: newS, difficulty: newD)
    }

    // MARK: - Clamping Helpers

    private func clampS(_ s: Double) -> Double {
        min(max(s, Self.sMin), Self.sMax)
    }

    private func clampD(_ d: Double) -> Double {
        min(max(d, Self.dMin), Self.dMax)
    }
}
