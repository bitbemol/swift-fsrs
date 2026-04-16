import Foundation
import Testing

@testable import FSRS

// MARK: - IntervalFuzzer Determinism
//
// These tests prove the seeded fuzzer is deterministic and matches
// ts-fsrs' `apply_fuzz` semantics (FLOOR, not round, over the range).

@Suite("IntervalFuzzer — determinism")
struct FuzzDeterminismTests {

    @Test("Same interval + seed produces the same output")
    func deterministic() {
        let a = IntervalFuzzer.fuzz(
            interval: 10,
            elapsedDays: 5,
            maximumInterval: 365,
            seed: "test"
        )
        let b = IntervalFuzzer.fuzz(
            interval: 10,
            elapsedDays: 5,
            maximumInterval: 365,
            seed: "test"
        )
        #expect(a == b)
    }

    @Test("Different seeds produce at least some variation")
    func seedMatters() {
        var outputs = Set<Int>()
        for i in 0..<20 {
            let v = IntervalFuzzer.fuzz(
                interval: 10,
                elapsedDays: 5,
                maximumInterval: 365,
                seed: "seed\(i)"
            )
            outputs.insert(v)
        }
        #expect(outputs.count > 1, "seed variation should produce different fuzz outputs")
    }

    @Test("Output stays within the computed fuzz range")
    func inRange() {
        // get_fuzz_range(interval: 10, elapsed_days: 5, max: 365):
        //   delta = 1 + 0.15*(7 - 2.5) + 0.10*(10 - 7) = 1 + 0.675 + 0.3 = 1.975
        //   min_ivl = max(2, round(10 - 1.975)) = max(2, 8) = 8
        //   max_ivl = min(round(10 + 1.975), 365) = 12
        //   interval(10) > elapsed(5), so min_ivl = max(8, 6) = 8
        for i in 0..<100 {
            let v = IntervalFuzzer.fuzz(
                interval: 10,
                elapsedDays: 5,
                maximumInterval: 365,
                seed: "s\(i)"
            )
            #expect(v >= 8, "got \(v) for seed s\(i)")
            #expect(v <= 12, "got \(v) for seed s\(i)")
        }
    }
}

// MARK: - Guard Path

@Suite("IntervalFuzzer — guard paths")
struct FuzzGuardTests {

    @Test("interval < 3 returns the original interval unchanged")
    func tinyInterval() {
        for ivl in 0...2 {
            let v = IntervalFuzzer.fuzz(
                interval: ivl,
                elapsedDays: 0,
                maximumInterval: 365,
                seed: "any"
            )
            #expect(v == ivl)
        }
    }

}

// MARK: - ts-fsrs Parity

@Suite("IntervalFuzzer — ts-fsrs parity")
struct FuzzParityTests {

    /// Reproduces ts-fsrs `apply_fuzz(ivl: 10, elapsed_days: 5)` with a
    /// known seed. The expected value is derived by hand from the
    /// reference alea vector:
    ///
    ///   seed "12345" -> first next() == 0.27138191112317145
    ///
    /// With `get_fuzz_range(10, 5, 365) = (min_ivl: 8, max_ivl: 12)`:
    ///   floor(0.27138... * (12 - 8 + 1) + 8)
    ///   = floor(0.27138... * 5 + 8)
    ///   = floor(9.35691...)
    ///   = 9
    @Test("fuzz(10, 5, 365, seed: '12345') == 9 (matches ts-fsrs by hand)")
    func fuzzSeed12345() {
        let v = IntervalFuzzer.fuzz(
            interval: 10,
            elapsedDays: 5,
            maximumInterval: 365,
            seed: "12345"
        )
        #expect(v == 9)
    }

    /// Another hand-derived vector exercising the wide range (interval=30).
    ///
    ///   get_fuzz_range(30, 0, 365):
    ///     delta = 1 + 0.15*(7 - 2.5) + 0.10*(20 - 7) + 0.05*(30 - 20)
    ///           = 1 + 0.675 + 1.3 + 0.5 = 3.475
    ///     min_ivl = max(2, round(30 - 3.475)) = 27  (round(26.525) = 27)
    ///     max_ivl = min(round(33.475), 365) = 33
    ///     interval(30) > elapsed(0), so min_ivl = max(27, 1) = 27
    ///
    ///   seed "12345" -> fuzz_factor = 0.27138191112317145
    ///   floor(0.27138... * (33 - 27 + 1) + 27)
    ///   = floor(0.27138... * 7 + 27)
    ///   = floor(28.8996...)
    ///   = 28
    @Test("fuzz(30, 0, 365, seed: '12345') == 28")
    func fuzzSeed12345WideRange() {
        let v = IntervalFuzzer.fuzz(
            interval: 30,
            elapsedDays: 0,
            maximumInterval: 365,
            seed: "12345"
        )
        #expect(v == 28)
    }

    /// Exercises the `interval <= elapsedDays` branch: fuzz should NOT
    /// bump the minimum above `elapsedDays + 1` when the interval itself
    /// hasn't grown past `elapsedDays`.
    @Test("interval == elapsedDays does not trigger the elapsed_days+1 bump")
    func fuzzAtElapsedBoundary() {
        // interval 10, elapsedDays 10: the `interval > elapsed_days`
        // branch does NOT fire, so min stays at 8.
        let v = IntervalFuzzer.fuzz(
            interval: 10,
            elapsedDays: 10,
            maximumInterval: 365,
            seed: "12345"
        )
        // range [8, 12], fuzz_factor = 0.27138... -> floor(0.271*5 + 8) = 9
        #expect(v == 9)
    }

    @Test("maximumInterval clamp caps the upper bound")
    func fuzzClampedByMax() {
        // interval 100, max 50: max_ivl clamped to 50. min_ivl = round(100 - delta)
        // capped at max_ivl via the final `min_ivl = min(min_ivl, max_ivl)`.
        // Whatever the fuzz factor, the result must be <= 50.
        for i in 0..<50 {
            let v = IntervalFuzzer.fuzz(
                interval: 100,
                elapsedDays: 0,
                maximumInterval: 50,
                seed: "s\(i)"
            )
            #expect(v <= 50, "got \(v) with maximumInterval=50")
        }
    }
}

// MARK: - Scheduler-Level Fuzz Determinism
//
// Regression tests for the bug where `fsrs.schedule(card:now:)` with
// `enableFuzz: true` returned different due dates on repeat calls. Each
// scheduler now derives a stable seed from `(now, reps, D*S)` so identical
// inputs produce identical outputs.

@Suite("Scheduler — fuzz determinism")
struct SchedulerFuzzDeterminismTests {

    /// Builds a review-state card whose FSRS intervals land in the fuzz
    /// zone (≥ 3 days) so the fuzz branch actually fires.
    private func makeReviewCard() -> Card {
        var card = Card()
        card.state = .review
        card.stability = 10
        card.difficulty = 5
        card.reps = 3
        // Fixed wall-clock; exact value doesn't matter for determinism, only
        // that both calls see the same `now`.
        card.lastReview = Date(timeIntervalSince1970: 1_700_000_000)
        return card
    }

    @Test("BasicScheduler: identical inputs yield identical due dates across all ratings")
    func basicSchedulerIdempotent() {
        let fsrs = FSRS(parameters: Parameters(enableFuzz: true))
        let card = makeReviewCard()
        let now = Date(timeIntervalSince1970: 1_700_864_000)  // 10 days later

        let r1 = fsrs.schedule(card: card, now: now)
        let r2 = fsrs.schedule(card: card, now: now)

        #expect(r1.again.card.due == r2.again.card.due)
        #expect(r1.hard.card.due == r2.hard.card.due)
        #expect(r1.good.card.due == r2.good.card.due)
        #expect(r1.easy.card.due == r2.easy.card.due)
    }

    @Test("LongTermScheduler: identical inputs yield identical due dates across all ratings")
    func longTermSchedulerIdempotent() {
        let fsrs = FSRS(parameters: Parameters(
            enableFuzz: true,
            enableShortTerm: false
        ))
        let card = makeReviewCard()
        let now = Date(timeIntervalSince1970: 1_700_864_000)  // 10 days later

        let r1 = fsrs.schedule(card: card, now: now)
        let r2 = fsrs.schedule(card: card, now: now)

        #expect(r1.again.card.due == r2.again.card.due)
        #expect(r1.hard.card.due == r2.hard.card.due)
        #expect(r1.good.card.due == r2.good.card.due)
        #expect(r1.easy.card.due == r2.easy.card.due)
    }

    @Test("Different reps produce different fuzzed due dates for at least one rating")
    func repsAffectsSeed() {
        let fsrs = FSRS(parameters: Parameters(enableFuzz: true))
        let now = Date(timeIntervalSince1970: 1_700_864_000)

        var cardA = makeReviewCard()
        cardA.reps = 3

        var cardB = makeReviewCard()
        cardB.reps = 4

        let rA = fsrs.schedule(card: cardA, now: now)
        let rB = fsrs.schedule(card: cardB, now: now)

        // `reps` is the only state difference. FSRS algorithm itself doesn't
        // read `reps` when computing intervals (only state/S/D/elapsed), so
        // any divergence in due dates must come from the fuzz seed including
        // `reps`. At least one of Hard/Good/Easy should differ.
        let anyDifferent =
            rA.hard.card.due != rB.hard.card.due ||
            rA.good.card.due != rB.good.card.due ||
            rA.easy.card.due != rB.easy.card.due
        #expect(anyDifferent, "reps should feed into the fuzz seed")
    }
}
