import Foundation
import Testing

@testable import FSRS

// MARK: - Algorithm Parity Tests
//
// Byte-exact (`==`, no tolerance) cross-checks of the 9 core `FSRSAlgorithm`
// formulas against the canonical ts-fsrs reference values. Reference vectors
// are taken verbatim from:
//
//   /tmp/ts-fsrs-audit/packages/fsrs/__tests__/algorithm.test.ts
//   /tmp/ts-fsrs-audit/packages/fsrs/__tests__/FSRS-6.test.ts
//
// Additional vectors were computed via the Python ts-fsrs port at
// /tmp/fsrs_ref.py (a faithful re-implementation of algorithm.ts that
// reproduces ts-fsrs's `roundTo(_, 8)` and JS `Math.round` semantics).
//
// Every assertion uses exact `==`. A failure here means real numerical
// divergence from ts-fsrs — do NOT lower the assertion to a tolerance.
//
// All tests use the v6 default weights (`Parameters()` → `Weights.default`).

@Suite("Algorithm parity — forgettingCurve")
struct ForgettingCurveParityTests {
    let algo = FSRSAlgorithm(parameters: Parameters())

    /// algorithm.test.ts:114
    /// `expect(collection).toEqual([1.0, 0.9, 0.84588465, 0.8093881])`
    /// for `delta_t = [0, 1, 2, 3]`, `s = 1.0`, default v6 w.
    @Test("R(t, 1.0) for t = 0..3 (algorithm.test.ts:114)")
    func curveAtSEquals1() {
        #expect(algo.forgettingCurve(elapsedDays: 0, stability: 1.0) == 1.0)
        #expect(algo.forgettingCurve(elapsedDays: 1, stability: 1.0) == 0.9)
        #expect(algo.forgettingCurve(elapsedDays: 2, stability: 1.0) == 0.84588465)
        #expect(algo.forgettingCurve(elapsedDays: 3, stability: 1.0) == 0.8093881)
    }

    /// Cross-check from /tmp/fsrs_ref.py (Python port of algorithm.ts).
    /// Verifies the curve at varied stabilities and the by-construction
    /// identity R(S, S) = 0.9.
    @Test("R(t, S) at various S — Python ref vectors")
    func curveVariedS() {
        #expect(algo.forgettingCurve(elapsedDays: 0, stability: 5.0) == 1.0)
        #expect(algo.forgettingCurve(elapsedDays: 1, stability: 5.0) == 0.97276956)
        #expect(algo.forgettingCurve(elapsedDays: 5, stability: 5.0) == 0.9)
        #expect(algo.forgettingCurve(elapsedDays: 10, stability: 5.0) == 0.84588465)
        #expect(algo.forgettingCurve(elapsedDays: 50, stability: 100.0) == 0.94034429)
        #expect(algo.forgettingCurve(elapsedDays: 100, stability: 100.0) == 0.9)
        #expect(algo.forgettingCurve(elapsedDays: 200, stability: 100.0) == 0.84588465)
    }

    /// Edge cases: very small S (close to S_MIN) and very large S (close to S_MAX).
    /// Reference values from /tmp/fsrs_ref.py.
    @Test("R(t, S) extremes — Python ref vectors")
    func curveExtremes() {
        #expect(algo.forgettingCurve(elapsedDays: 1, stability: 0.001) == 0.34566944)
        #expect(algo.forgettingCurve(elapsedDays: 1, stability: 36500.0) == 0.99999586)
    }
}

@Suite("Algorithm parity — initialStability")
struct InitialStabilityParityTests {
    let algo = FSRSAlgorithm(parameters: Parameters())

    /// algorithm.test.ts:129-134 — `init_stability(grade)` returns `w[grade-1]`
    /// for each grade. Also locked in by FSRS-6.test.ts:153
    /// `expect(stability).toEqual([0.212, 1.2931, 2.3065, 8.2956])`.
    @Test("S0(G) == w[G-1] for all four grades (algorithm.test.ts:129; FSRS-6.test.ts:153)")
    func initStabilityAllGrades() {
        #expect(algo.initialStability(rating: .again) == 0.212)
        #expect(algo.initialStability(rating: .hard)  == 1.2931)
        #expect(algo.initialStability(rating: .good)  == 2.3065)
        #expect(algo.initialStability(rating: .easy)  == 8.2956)
    }
}

@Suite("Algorithm parity — initialDifficulty")
struct InitialDifficultyParityTests {
    let algo = FSRSAlgorithm(parameters: Parameters())

    /// FSRS-6.test.ts:154 — `expect(difficulty).toEqual([6.4133, 5.11217071, 2.11810397, 1])`
    /// for the first review of a new card under default v6 w.
    /// (For Easy, the unclamped formula gives ≈ -4.7716307, which is clamped to 1.0.)
    @Test("D0(G) for all four grades (FSRS-6.test.ts:154)")
    func initDifficultyAllGrades() {
        #expect(algo.initialDifficulty(rating: .again) == 6.4133)
        #expect(algo.initialDifficulty(rating: .hard)  == 5.11217071)
        #expect(algo.initialDifficulty(rating: .good)  == 2.11810397)
        #expect(algo.initialDifficulty(rating: .easy)  == 1.0)
    }
}

@Suite("Algorithm parity — nextDifficulty")
struct NextDifficultyParityTests {
    let algo = FSRSAlgorithm(parameters: Parameters())

    /// algorithm.test.ts:202-204
    /// `expect(collection).toEqual([8.341_762_37, 6.665_995_36, 4.990_228_37, 3.314_461_37])`
    /// for `d = 5.0`, grades [Again, Hard, Good, Easy] under default v6 w.
    @Test("D' from D=5 for all grades (algorithm.test.ts:202)")
    func nextDFromFive() {
        #expect(algo.nextDifficulty(current: 5.0, rating: .again) == 8.34176237)
        #expect(algo.nextDifficulty(current: 5.0, rating: .hard)  == 6.66599536)
        #expect(algo.nextDifficulty(current: 5.0, rating: .good)  == 4.99022837)
        #expect(algo.nextDifficulty(current: 5.0, rating: .easy)  == 3.31446137)
    }

    /// Cross-check vectors from /tmp/fsrs_ref.py covering low-D and high-D
    /// regimes (where clamping to [1, 10] kicks in for low-D Good/Easy and
    /// where linear damping is small for high-D).
    @Test("D' from low D — Python ref vectors")
    func nextDLow() {
        #expect(algo.nextDifficulty(current: 1.0, rating: .again) == 7.02698957)
        #expect(algo.nextDifficulty(current: 1.0, rating: .hard)  == 4.01060897)
        #expect(algo.nextDifficulty(current: 1.0, rating: .good)  == 1.0)   // mean-reversion + clamp
        #expect(algo.nextDifficulty(current: 1.0, rating: .easy)  == 1.0)   // mean-reversion + clamp
        #expect(algo.nextDifficulty(current: 2.5, rating: .again) == 7.52002937)
        #expect(algo.nextDifficulty(current: 2.5, rating: .easy)  == 1.0)
    }

    @Test("D' from high D — Python ref vectors")
    func nextDHigh() {
        #expect(algo.nextDifficulty(current: 7.5, rating: .again) == 9.16349536)
        #expect(algo.nextDifficulty(current: 7.5, rating: .hard)  == 8.32561187)
        #expect(algo.nextDifficulty(current: 7.5, rating: .good)  == 7.48772837)
        #expect(algo.nextDifficulty(current: 7.5, rating: .easy)  == 6.64984487)
        #expect(algo.nextDifficulty(current: 9.5, rating: .again) == 9.82088177)
        #expect(algo.nextDifficulty(current: 9.5, rating: .easy)  == 9.31815167)
    }
}

@Suite("Algorithm parity — nextRecallStability")
struct NextRecallStabilityParityTests {
    let algo = FSRSAlgorithm(parameters: Parameters())

    /// algorithm.test.ts:311-313
    /// `expect(s_recall_collection).toEqual([25.602_521_18, 28.226_570_96, 58.655_991_07, 127.226_692_5])`
    /// for d=[1,2,3,4], s=[5,5,5,5], r=[0.9,0.8,0.7,0.6], grades [Again, Hard, Good, Easy].
    /// (The first entry — Again — is computed but unused; we still verify
    /// the Hard/Good/Easy entries.)
    @Test("Sr (Hard/Good/Easy) at d=2..4, s=5, varied r (algorithm.test.ts:311)")
    func recallStabilityHardcoded() {
        #expect(algo.nextRecallStability(d: 2.0, s: 5.0, r: 0.8, rating: .hard) == 28.22657096)
        #expect(algo.nextRecallStability(d: 3.0, s: 5.0, r: 0.7, rating: .good) == 58.65599107)
        #expect(algo.nextRecallStability(d: 4.0, s: 5.0, r: 0.6, rating: .easy) == 127.2266925)
    }

    /// Mid-range vectors at D=5, S=10, R=0.9 from /tmp/fsrs_ref.py.
    @Test("Sr at D=5, S=10, R=0.9 — Python ref vectors")
    func recallStabilityMid() {
        #expect(algo.nextRecallStability(d: 5.0, s: 10.0, r: 0.9, rating: .hard) == 23.24687511)
        #expect(algo.nextRecallStability(d: 5.0, s: 10.0, r: 0.9, rating: .good) == 32.02672948)
        #expect(algo.nextRecallStability(d: 5.0, s: 10.0, r: 0.9, rating: .easy) == 51.25386165)
    }

    /// Extreme regimes (low/high D, low/high S) from /tmp/fsrs_ref.py.
    @Test("Sr extremes — Python ref vectors")
    func recallStabilityExtremes() {
        // Low D (max gain) + high S + low R (spacing effect)
        #expect(algo.nextRecallStability(d: 1.0, s: 100.0, r: 0.5, rating: .good) == 1575.89834135)
        // High D (min gain) + same S/R
        #expect(algo.nextRecallStability(d: 10.0, s: 100.0, r: 0.5, rating: .good) == 247.58983414)
        // Tiny S, near-1 R (early review of a fresh card)
        #expect(algo.nextRecallStability(d: 1.0, s: 0.5, r: 0.99, rating: .good) == 0.79164225)
        // Easy bonus on small S
        #expect(algo.nextRecallStability(d: 5.0, s: 1.0, r: 0.7, rating: .easy) == 20.70935775)
    }
}

@Suite("Algorithm parity — nextForgetStability")
struct NextForgetStabilityParityTests {
    let algo = FSRSAlgorithm(parameters: Parameters())

    /// algorithm.test.ts:315-317
    /// `expect(s_fail_collection).toEqual([1.052_539_61, 1.189_432_95, 1.368_083_87, 1.584_988_96])`
    /// for d=[1,2,3,4], s=[5,5,5,5], r=[0.9,0.8,0.7,0.6].
    @Test("Sf at d=1..4, s=5, varied r (algorithm.test.ts:315)")
    func forgetStabilityHardcoded() {
        #expect(algo.nextForgetStability(d: 1.0, s: 5.0, r: 0.9) == 1.05253961)
        #expect(algo.nextForgetStability(d: 2.0, s: 5.0, r: 0.8) == 1.18943295)
        #expect(algo.nextForgetStability(d: 3.0, s: 5.0, r: 0.7) == 1.36808387)
        #expect(algo.nextForgetStability(d: 4.0, s: 5.0, r: 0.6) == 1.58498896)
    }

    /// Cross-check vectors from /tmp/fsrs_ref.py covering varied D, S, R.
    @Test("Sf — Python ref vectors")
    func forgetStabilityExtra() {
        #expect(algo.nextForgetStability(d: 5.0, s: 20.0, r: 0.9) == 1.94358119)
        #expect(algo.nextForgetStability(d: 5.0, s: 20.0, r: 0.5) == 3.75786977)
        #expect(algo.nextForgetStability(d: 1.0, s: 10.0, r: 0.8) == 1.81191028)
        #expect(algo.nextForgetStability(d: 10.0, s: 10.0, r: 0.8) == 1.57302885)
        #expect(algo.nextForgetStability(d: 5.0, s: 100.0, r: 0.7) == 5.21058548)
        #expect(algo.nextForgetStability(d: 5.0, s: 0.5, r: 0.95) == 0.16415724)
    }
}

@Suite("Algorithm parity — nextShortTermStability")
struct NextShortTermStabilityParityTests {
    let algo = FSRSAlgorithm(parameters: Parameters())

    /// algorithm.test.ts:320 — `expect(s_short_collection).toEqual([1.596_818, 5, 5, 8.129_609_56])`
    /// for s=5, grades [Again, Hard, Good, Easy].
    /// (For Hard/Good with s=5, the masked sinc clamps at 1.0, so S' == S.)
    @Test("Ss at S=5 for all four grades (algorithm.test.ts:320)")
    func shortTermAtSEquals5() {
        #expect(algo.nextShortTermStability(s: 5.0, rating: .again) == 1.596818)
        #expect(algo.nextShortTermStability(s: 5.0, rating: .hard)  == 5.0)
        #expect(algo.nextShortTermStability(s: 5.0, rating: .good)  == 5.0)
        #expect(algo.nextShortTermStability(s: 5.0, rating: .easy)  == 8.12960956)
    }

    /// Cross-check vectors at varied S (low/mid/high) from /tmp/fsrs_ref.py.
    /// Note: at large S the v6 dampening term S^(-w[19]) drives sinc below 1,
    /// so Hard/Good clamp at S' == S (no growth).
    @Test("Ss varied S — Python ref vectors")
    func shortTermVariedS() {
        #expect(algo.nextShortTermStability(s: 1.0, rating: .again) == 0.35504029)
        #expect(algo.nextShortTermStability(s: 1.0, rating: .hard)  == 1.0)
        #expect(algo.nextShortTermStability(s: 1.0, rating: .good)  == 1.05072037)
        #expect(algo.nextShortTermStability(s: 1.0, rating: .easy)  == 1.80755662)
        #expect(algo.nextShortTermStability(s: 10.0, rating: .again) == 3.05124894)
        #expect(algo.nextShortTermStability(s: 10.0, rating: .easy)  == 15.53430795)
        #expect(algo.nextShortTermStability(s: 50.0, rating: .good)  == 50.0)
        #expect(algo.nextShortTermStability(s: 100.0, rating: .good) == 100.0)
        #expect(algo.nextShortTermStability(s: 0.5, rating: .hard)   == 0.5)
    }
}

@Suite("Algorithm parity — nextState")
struct NextStateParityTests {
    let algo = FSRSAlgorithm(parameters: Parameters())  // enableShortTerm = true (default)

    /// New card (s=0, d=0) routes to initialStability/initialDifficulty.
    /// Expected values match FSRS-6.test.ts:153-154 (the first-repeat vector).
    @Test("nextState from new card — all four grades (FSRS-6.test.ts:153)")
    func nextStateNew() {
        let r1 = algo.nextState(stability: 0, difficulty: 0, elapsedDays: 0, rating: .again)
        #expect(r1.stability == 0.212)
        #expect(r1.difficulty == 6.4133)

        let r2 = algo.nextState(stability: 0, difficulty: 0, elapsedDays: 0, rating: .hard)
        #expect(r2.stability == 1.2931)
        #expect(r2.difficulty == 5.11217071)

        let r3 = algo.nextState(stability: 0, difficulty: 0, elapsedDays: 0, rating: .good)
        #expect(r3.stability == 2.3065)
        #expect(r3.difficulty == 2.11810397)

        let r4 = algo.nextState(stability: 0, difficulty: 0, elapsedDays: 0, rating: .easy)
        #expect(r4.stability == 8.2956)
        #expect(r4.difficulty == 1.0)
    }

    /// Same-day Good (t=0, enableShortTerm=true) routes to nextShortTermStability.
    /// Reference value from /tmp/fsrs_ref.py: at S=10, Good clamps to S' = S = 10.
    @Test("nextState same-day Good (t=0, short-term) — Python ref vector")
    func nextStateSameDayGood() {
        let r = algo.nextState(stability: 10.0, difficulty: 5.0, elapsedDays: 0, rating: .good)
        #expect(r.stability == 10.0)
        #expect(r.difficulty == 4.99022837)
    }

    /// Successful recall path (Hard/Good/Easy at t≥1) routes to nextRecallStability.
    /// Reference values from /tmp/fsrs_ref.py.
    @Test("nextState recall at S=10, D=5, t=5 — Python ref vectors")
    func nextStateRecall() {
        let h = algo.nextState(stability: 10.0, difficulty: 5.0, elapsedDays: 5, rating: .hard)
        #expect(h.stability == 17.77531755)
        #expect(h.difficulty == 6.66599536)

        let g = algo.nextState(stability: 10.0, difficulty: 5.0, elapsedDays: 5, rating: .good)
        #expect(g.stability == 22.92869563)
        #expect(g.difficulty == 4.99022837)

        let e = algo.nextState(stability: 10.0, difficulty: 5.0, elapsedDays: 5, rating: .easy)
        #expect(e.stability == 34.21415404)
        #expect(e.difficulty == 3.31446137)
    }

    /// Lapse path (Again at t≥1) routes to nextForgetStability with the
    /// post-lapse floor `s / exp(w[17] * w[18])` clamped against the formula
    /// result. Reference value from /tmp/fsrs_ref.py — note that with
    /// short-term enabled the floor (≈9.51) is BELOW the forget formula, so
    /// the floor wins (the clamp returns min(floor, sf)).
    @Test("nextState lapse at S=10, D=5, t=5 (short-term on) — Python ref vector")
    func nextStateLapseShortTerm() {
        let r = algo.nextState(stability: 10.0, difficulty: 5.0, elapsedDays: 5, rating: .again)
        #expect(r.stability == 1.30243125)
        #expect(r.difficulty == 8.34176237)
    }

    /// High-S, mature card good recall and lapse from /tmp/fsrs_ref.py.
    @Test("nextState mature card — Python ref vectors")
    func nextStateMature() {
        let g = algo.nextState(stability: 50.0, difficulty: 7.0, elapsedDays: 30, rating: .good)
        #expect(g.stability == 88.1798008)
        #expect(g.difficulty == 6.98822837)

        let a = algo.nextState(stability: 50.0, difficulty: 7.0, elapsedDays: 30, rating: .again)
        #expect(a.stability == 2.67112701)
        #expect(a.difficulty == 8.99914877)
    }

    /// High-D, low-S lapse — verifies clamp on D (the formula push is
    /// dampened near D=10).
    @Test("nextState high-D lapse — Python ref vector")
    func nextStateHighD() {
        let r = algo.nextState(stability: 2.0, difficulty: 9.0, elapsedDays: 1, rating: .again)
        #expect(r.stability == 0.47891956)
        #expect(r.difficulty == 9.65653517)
    }

    /// Long-term mode (enableShortTerm = false) — the post-lapse floor
    /// becomes plain `s` (no exp(w17*w18) divisor). Reference values from
    /// /tmp/fsrs_ref.py with `enable_short_term=False`. Note: in long-term
    /// mode the floor (S=10) is again below sf for these inputs, so the
    /// final S matches the short-term case for this particular vector.
    /// What we're really verifying here is that the long-term branch wires
    /// up the same way as ts-fsrs.
    @Test("nextState long-term mode — Python ref vectors")
    func nextStateLongTerm() {
        let lt = FSRSAlgorithm(parameters: Parameters(enableShortTerm: false))
        let a = lt.nextState(stability: 10.0, difficulty: 5.0, elapsedDays: 5, rating: .again)
        #expect(a.stability == 1.30243125)
        #expect(a.difficulty == 8.34176237)

        let g = lt.nextState(stability: 10.0, difficulty: 5.0, elapsedDays: 5, rating: .good)
        #expect(g.stability == 22.92869563)
        #expect(g.difficulty == 4.99022837)
    }
}

@Suite("Algorithm parity — nextInterval")
struct NextIntervalParityTests {

    /// algorithm.test.ts:347-358 — at S=1.0 with `maximum_interval =
    /// Number.MAX_VALUE` and request_retention varying from 0.1 to 1.0:
    /// `[3116766+3, 34793, 2508, 387, 90, 27, 9, 3, 1, 1]` (the +3 comment
    /// notes ts-fsrs uses f64 vs fsrs-rs's f32 — the +3 is the f64 value).
    ///
    /// Swift `Parameters.requestRetention` is clamped to `[0.01, 0.99]`, so
    /// we skip r=1.0 (the clamp would silently change input). r=0.1 is
    /// INSIDE the clamp range so it stays.
    @Test("Interval at S=1, r=0.1..0.9 (algorithm.test.ts:347)")
    func intervalReferenceTable() {
        // Swift Int is 64-bit on macOS; Int.max ≈ 9.22e18, well above the
        // 3_116_769 we need to fit unclamped.
        let bigMax = Int.max

        let r01 = FSRSAlgorithm(parameters: Parameters(requestRetention: 0.1, maximumInterval: bigMax))
        #expect(r01.nextInterval(stability: 1.0) == 3_116_769)

        let r02 = FSRSAlgorithm(parameters: Parameters(requestRetention: 0.2, maximumInterval: bigMax))
        #expect(r02.nextInterval(stability: 1.0) == 34_793)

        let r03 = FSRSAlgorithm(parameters: Parameters(requestRetention: 0.3, maximumInterval: bigMax))
        #expect(r03.nextInterval(stability: 1.0) == 2_508)

        let r04 = FSRSAlgorithm(parameters: Parameters(requestRetention: 0.4, maximumInterval: bigMax))
        #expect(r04.nextInterval(stability: 1.0) == 387)

        let r05 = FSRSAlgorithm(parameters: Parameters(requestRetention: 0.5, maximumInterval: bigMax))
        #expect(r05.nextInterval(stability: 1.0) == 90)

        let r06 = FSRSAlgorithm(parameters: Parameters(requestRetention: 0.6, maximumInterval: bigMax))
        #expect(r06.nextInterval(stability: 1.0) == 27)

        let r07 = FSRSAlgorithm(parameters: Parameters(requestRetention: 0.7, maximumInterval: bigMax))
        #expect(r07.nextInterval(stability: 1.0) == 9)

        let r08 = FSRSAlgorithm(parameters: Parameters(requestRetention: 0.8, maximumInterval: bigMax))
        #expect(r08.nextInterval(stability: 1.0) == 3)

        let r09 = FSRSAlgorithm(parameters: Parameters(requestRetention: 0.9, maximumInterval: bigMax))
        #expect(r09.nextInterval(stability: 1.0) == 1)
    }

    /// Default config (request_retention = 0.9, max = 36500) — when r=0.9
    /// the intervalModifier collapses to 1.0 by construction, so
    /// nextInterval(S) ≈ round(S). Reference values from /tmp/fsrs_ref.py.
    @Test("Interval at default config — Python ref vectors")
    func intervalDefaultConfig() {
        let algo = FSRSAlgorithm(parameters: Parameters())
        #expect(algo.nextInterval(stability: 0.5) == 1)         // floor clamp
        #expect(algo.nextInterval(stability: 1.0) == 1)
        #expect(algo.nextInterval(stability: 2.3065) == 2)
        #expect(algo.nextInterval(stability: 8.2956) == 8)
        #expect(algo.nextInterval(stability: 10.0) == 10)
        #expect(algo.nextInterval(stability: 30.0) == 30)
        #expect(algo.nextInterval(stability: 100.0) == 100)
        #expect(algo.nextInterval(stability: 1000.0) == 1000)
        #expect(algo.nextInterval(stability: 50_000.0) == 36_500)  // ceiling clamp
    }
}
