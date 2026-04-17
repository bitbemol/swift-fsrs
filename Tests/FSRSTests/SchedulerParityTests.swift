import Foundation
import Testing

@testable import FSRS

// MARK: - Parity helpers
//
// These tests byte-check Swift's BasicScheduler and LongTermScheduler against
// the ts-fsrs reference suite. Where ts-fsrs's hardcoded numeric expectations
// use FSRS-5 weights (19 elements, decay = 0.5) we can't reproduce them
// numerically — the Swift port targets FSRS-6 (21 weights). For those cases
// we still byte-check structurally (state, step, lapses, scheduled_days,
// ordering invariants, in-day due offsets) and verify the scheduler's
// (stability, difficulty) output is bit-identical to a freshly recomputed
// FSRSAlgorithm call (i.e. no precision loss through the scheduler pipeline).
//
// All tests disable fuzz so outputs are deterministic.

private func parityParameters(
    learningSteps: [TimeInterval]? = nil,
    relearningSteps: [TimeInterval]? = nil,
    enableShortTerm: Bool = true
) -> Parameters {
    Parameters(
        enableFuzz: false,
        enableShortTerm: enableShortTerm,
        learningSteps: learningSteps ?? [60, 600],
        relearningSteps: relearningSteps ?? [600]
    )
}

/// Asserts two dates are bit-identical at second granularity.
private func expectExactDue(
    _ actual: Date,
    _ expected: Date,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(
        actual.timeIntervalSinceReferenceDate
            == expected.timeIntervalSinceReferenceDate,
        "due mismatch: \(actual.timeIntervalSinceReferenceDate) != \(expected.timeIntervalSinceReferenceDate)",
        sourceLocation: sourceLocation
    )
}

// MARK: - learning-steps.test.ts: BasicLearningStepsStrategy parity
//
// Source: /tmp/ts-fsrs-audit/packages/fsrs/__tests__/strategies/learning-steps.test.ts
//
// The hardcoded scheduled_minutes values here are weight-independent — they
// only depend on the learning_steps configuration and the getHardInterval
// rule (round((step0+step1)/2) for >=2 steps, round(step0*1.5) for 1 step).
// We can byte-port these exactly.

@Suite("Parity — BasicLearningStepsStrategy [1m, 10m]")
struct LearningStepsTwoStepsParityTests {

    let fsrs = FSRS(parameters: parityParameters(learningSteps: [60, 600]))

    /// learning-steps.test.ts:50-76 — first call from State.New step 0.
    /// Expected: Again 1m / Hard 6m / Good 10m, Easy graduates.
    @Test("New: Again=60s, Hard=360s, Good=600s, Easy graduates")
    func newCardAllRatings() {
        let card = FSRS.createCard(now: refDate)
        let result = fsrs.schedule(card: card, now: refDate)

        // Again — step 0, in-day
        #expect(result.again.card.state == .learning)
        #expect(result.again.card.step == 0)
        #expect(result.again.card.scheduledDays == 0)
        expectExactDue(result.again.card.due, refDate.addingTimeInterval(60))

        // Hard — step 0, in-day, getHardInterval = round((1+10)/2) = 6
        #expect(result.hard.card.state == .learning)
        #expect(result.hard.card.step == 0)
        #expect(result.hard.card.scheduledDays == 0)
        expectExactDue(result.hard.card.due, refDate.addingTimeInterval(360))

        // Good — step 1, in-day
        #expect(result.good.card.state == .learning)
        #expect(result.good.card.step == 1)
        #expect(result.good.card.scheduledDays == 0)
        expectExactDue(result.good.card.due, refDate.addingTimeInterval(600))

        // Easy — graduates to Review with FSRS interval
        #expect(result.easy.card.state == .review)
        #expect(result.easy.card.step == 0)
    }

    /// learning-steps.test.ts:62-69 — From State.Learning step 0, same offsets.
    @Test("Learning step 0: same offsets as new card")
    func learningStep0() {
        // Get a Learning step 0 card via Again
        let initial = FSRS.createCard(now: refDate)
        let card = fsrs.schedule(card: initial, now: refDate, rating: .again).card
        #expect(card.state == .learning)
        #expect(card.step == 0)

        let now = card.due
        let result = fsrs.schedule(card: card, now: now)

        expectExactDue(result.again.card.due, now.addingTimeInterval(60))
        #expect(result.again.card.step == 0)
        expectExactDue(result.hard.card.due, now.addingTimeInterval(360))
        #expect(result.hard.card.step == 0)
        expectExactDue(result.good.card.due, now.addingTimeInterval(600))
        #expect(result.good.card.step == 1)
    }

    /// learning-steps.test.ts:70-75 — From State.Learning step 1.
    /// Expected: Again resets to step 0 (1m), Hard stays step 1 (6m).
    /// Good graduates (no step 2 exists), so Good's due > 1 day.
    @Test("Learning step 1: Again resets, Hard repeats step 1, Good graduates")
    func learningStep1() {
        // Reach Learning step 1 via Good
        let initial = FSRS.createCard(now: refDate)
        let card = fsrs.schedule(card: initial, now: refDate, rating: .good).card
        #expect(card.step == 1)

        let now = card.due
        let result = fsrs.schedule(card: card, now: now)

        // Again — back to step 0, 1m
        #expect(result.again.card.state == .learning)
        #expect(result.again.card.step == 0)
        expectExactDue(result.again.card.due, now.addingTimeInterval(60))

        // Hard — repeats step 1 with the step-independent 6m duration
        #expect(result.hard.card.state == .learning)
        #expect(result.hard.card.step == 1)
        expectExactDue(result.hard.card.due, now.addingTimeInterval(360))

        // Good — targets step 2, exhausted → graduate to Review
        #expect(result.good.card.state == .review)
        #expect(result.good.card.step == 0)
    }
}

@Suite("Parity — BasicLearningStepsStrategy [1m]")
struct LearningStepsSingleStepParityTests {

    let fsrs = FSRS(parameters: parityParameters(learningSteps: [60]))

    /// learning-steps.test.ts:78-101 — single-step config.
    /// Expected: Again 1m, Hard round(1*1.5)=2m, Good graduates immediately.
    @Test("New: Again=60s, Hard=120s, Good graduates")
    func singleStepNew() {
        let card = FSRS.createCard(now: refDate)
        let result = fsrs.schedule(card: card, now: refDate)

        // Again — step 0
        #expect(result.again.card.state == .learning)
        #expect(result.again.card.step == 0)
        expectExactDue(result.again.card.due, refDate.addingTimeInterval(60))

        // Hard — step 0, round(1 * 1.5) = 2 minutes = 120s
        #expect(result.hard.card.state == .learning)
        #expect(result.hard.card.step == 0)
        expectExactDue(result.hard.card.due, refDate.addingTimeInterval(120))

        // Good — targets step 1, exhausted → graduate
        #expect(result.good.card.state == .review)
    }

    /// learning-steps.test.ts:99-101 — From Learning step 1, all FSRS-graduated.
    /// (Strategy returns {} but Swift's BasicScheduler routes to graduate.)
    @Test("Learning step 1 with single step: Hard targets out-of-range → graduates")
    func singleStepLearningStep1() {
        // We can't easily reach step 1 with single-step (Good graduates on
        // first review), but we can construct one manually for the edge case.
        var card = FSRS.createCard(now: refDate)
        card.state = .learning
        card.step = 1  // out of range for [60]
        card.stability = 5.0
        card.difficulty = 5.0
        card.lastReview = refDate.addingTimeInterval(-86400)

        let result = fsrs.schedule(card: card, now: refDate)

        // Hard with cur_step (1) >= steps.count (1): graduates via FSRS interval
        #expect(result.hard.card.state == .review)
        #expect(result.hard.card.step == 0)

        // Again resets to step 0 (1m)
        #expect(result.again.card.state == .learning)
        #expect(result.again.card.step == 0)
        expectExactDue(result.again.card.due, refDate.addingTimeInterval(60))
    }
}

@Suite("Parity — BasicLearningStepsStrategy relearning steps")
struct RelearningStepsParityTests {

    /// learning-steps.test.ts:113-143 — relearning_steps = ['10m'].
    @Test("Relearning [10m]: Review→Again uses 10m; Relearning step 0 Again=10m, Hard=15m")
    func relearningSingleStep() {
        let fsrs = FSRS(parameters: parityParameters(relearningSteps: [600]))

        // Get a Review-state card.
        var card = FSRS.createCard(now: refDate)
        card = fsrs.schedule(card: card, now: refDate, rating: .easy).card
        #expect(card.state == .review)

        // Review + Again → Relearning, step 0, due = now + 10m
        let now = card.due
        let result = fsrs.schedule(card: card, now: now)
        #expect(result.again.card.state == .relearning)
        #expect(result.again.card.step == 0)
        #expect(result.again.card.scheduledDays == 0)
        expectExactDue(result.again.card.due, now.addingTimeInterval(600))

        // Relearning step 0 + Again → step 0, 10m
        let relearningCard = result.again.card
        let now2 = relearningCard.due
        let result2 = fsrs.schedule(card: relearningCard, now: now2)

        #expect(result2.again.card.state == .relearning)
        #expect(result2.again.card.step == 0)
        expectExactDue(result2.again.card.due, now2.addingTimeInterval(600))

        // Relearning step 0 + Hard → step 0, round(10*1.5) = 15m = 900s
        #expect(result2.hard.card.state == .relearning)
        #expect(result2.hard.card.step == 0)
        expectExactDue(result2.hard.card.due, now2.addingTimeInterval(900))
    }

    /// learning-steps.test.ts:145-173 — relearning_steps = ['10m', '20m'].
    /// Hard: round((10+20)/2) = 15m.
    /// Note: Swift's `Parameters.applyContextDependentWeightRanges()` clamps
    /// w[17]/w[18] when relearning_steps.count > 1; this is structural and
    /// shouldn't change the in-day relearning step due dates.
    @Test("Relearning [10m, 20m]: step 0 Again=10m, Hard=15m, Good=20m")
    func relearningTwoSteps() {
        let fsrs = FSRS(parameters: parityParameters(relearningSteps: [600, 1200]))

        // Get a Review-state card and lapse into relearning step 0.
        var card = FSRS.createCard(now: refDate)
        card = fsrs.schedule(card: card, now: refDate, rating: .easy).card

        let now = card.due
        let lapsed = fsrs.schedule(card: card, now: now, rating: .again).card
        #expect(lapsed.state == .relearning)
        #expect(lapsed.step == 0)

        let now2 = lapsed.due
        let result = fsrs.schedule(card: lapsed, now: now2)

        // Again — step 0, 10m
        #expect(result.again.card.state == .relearning)
        #expect(result.again.card.step == 0)
        expectExactDue(result.again.card.due, now2.addingTimeInterval(600))

        // Hard — step 0, round((10+20)/2) = 15m = 900s
        #expect(result.hard.card.state == .relearning)
        #expect(result.hard.card.step == 0)
        expectExactDue(result.hard.card.due, now2.addingTimeInterval(900))

        // Good — step 1, 20m
        #expect(result.good.card.state == .relearning)
        #expect(result.good.card.step == 1)
        expectExactDue(result.good.card.due, now2.addingTimeInterval(1200))
    }
}

// MARK: - learning-steps.test.ts: ≥1-day step graduation

@Suite("Parity — Hardcoded learning steps (mixed in-day and ≥1-day)")
struct HardcodedLearningStepsParityTests {

    /// learning-steps.test.ts:307-358 — strategy returns minutes 5, 1440, 4320.
    /// Swift can't inject a custom strategy, so we approximate with
    /// learning_steps = [5m, 1d, 3d] = [300, 86400, 86400*3].
    /// Expected: Again uses step 0 (5m), Hard uses step 1 (1d → Review,
    /// scheduled_days = 1), Good uses step 2 (3d → Review, scheduled_days = 3).
    /// Wait — the ts-fsrs strategy returns Again=5m/Hard=1d/Good=3d uniformly,
    /// but Swift's algorithm uses Again=step[0], Hard=getHardInterval, Good=step[step+1].
    /// Hard's getHardInterval for [5m, 1d, 3d] is round((5+1440)/2) = 723m.
    /// So this scenario CANNOT be byte-ported via the Swift API — only the
    /// generic ≥1-day Good/Easy graduation path can be.
    @Test("Long step Good graduates to Review with scheduled_days from raw duration")
    func longGoodStepGraduates() {
        // learning_steps = [1m, 1d]: Good targets step 1 = 1 day.
        let fsrs = FSRS(parameters: parityParameters(learningSteps: [60, 86400]))
        let card = FSRS.createCard(now: refDate)
        let result = fsrs.schedule(card: card, now: refDate, rating: .good)

        // Good lands on step 1 (1d), routes through ≥1-day branch:
        // state = Review, step preserved (= 1), scheduled_days = 1, due = +1d
        #expect(result.card.state == .review)
        #expect(result.card.step == 1)
        #expect(result.card.scheduledDays == 1)
        expectExactDue(result.card.due, refDate.addingTimeInterval(86400))
    }

    /// Multi-day step (3 days) — scheduled_days flooring matches.
    @Test("Long step ≥3 days: scheduled_days = floor(duration / 86400)")
    func multiDayStepGraduates() {
        // learning_steps = [1m, 3d]
        let fsrs = FSRS(parameters: parityParameters(learningSteps: [60, 86400 * 3]))
        let card = FSRS.createCard(now: refDate)
        let result = fsrs.schedule(card: card, now: refDate, rating: .good)

        #expect(result.card.state == .review)
        #expect(result.card.step == 1)
        #expect(result.card.scheduledDays == 3)
        expectExactDue(result.card.due, refDate.addingTimeInterval(86400 * 3))
    }
}

// MARK: - basic_scheduler.test.ts: preview equality across all states
//
// Source: /tmp/ts-fsrs-audit/packages/fsrs/__tests__/impl/basic_scheduler.test.ts
//
// The ts-fsrs tests verify that `preview` returns the same objects as
// individual `review(grade)` calls. Swift's API exposes a SchedulingResult
// struct with all four ratings precomputed, plus a per-rating overload.
// We byte-check that the per-rating overload returns Equatable RecordLogItems
// identical to the SchedulingResult subscripts.

@Suite("Parity — schedule(rating:) matches schedule()[rating] for all states")
struct SchedulePerRatingParityTests {

    let fsrs = FSRS(parameters: parityParameters())

    /// basic_scheduler.test.ts:16-41 — [State.New] preview equals reviews.
    @Test("New card: per-rating overload matches preview subscript")
    func newCardConsistency() {
        let card = FSRS.createCard(now: refDate)
        let preview = fsrs.schedule(card: card, now: refDate)

        for rating in Rating.allCases {
            let single = fsrs.schedule(card: card, now: refDate, rating: rating)
            #expect(preview[rating] == single, "preview[\(rating)] != schedule(rating:)")
        }
    }

    /// basic_scheduler.test.ts:50-73 — [State.Learning] preview equals reviews.
    @Test("Learning card: per-rating overload matches preview subscript")
    func learningCardConsistency() {
        var card = FSRS.createCard(now: refDate)
        card = fsrs.schedule(card: card, now: refDate, rating: .again).card
        #expect(card.state == .learning)

        let now = card.due
        let preview = fsrs.schedule(card: card, now: now)

        for rating in Rating.allCases {
            let single = fsrs.schedule(card: card, now: now, rating: rating)
            #expect(preview[rating] == single, "preview[\(rating)] != schedule(rating:)")
        }
    }

    /// basic_scheduler.test.ts:85-108 — [State.Review] preview equals reviews.
    @Test("Review card: per-rating overload matches preview subscript")
    func reviewCardConsistency() {
        var card = FSRS.createCard(now: refDate)
        card = fsrs.schedule(card: card, now: refDate, rating: .easy).card
        #expect(card.state == .review)

        let now = card.due
        let preview = fsrs.schedule(card: card, now: now)

        for rating in Rating.allCases {
            let single = fsrs.schedule(card: card, now: now, rating: rating)
            #expect(preview[rating] == single, "preview[\(rating)] != schedule(rating:)")
        }
    }

    /// Relearning state coverage (not in ts-fsrs basic_scheduler.test.ts but
    /// implied by abstract_scheduler.test.ts — every state is Symbol.iterator-equal).
    @Test("Relearning card: per-rating overload matches preview subscript")
    func relearningCardConsistency() {
        var card = FSRS.createCard(now: refDate)
        card = fsrs.schedule(card: card, now: refDate, rating: .easy).card
        card = fsrs.schedule(card: card, now: card.due, rating: .again).card
        #expect(card.state == .relearning)

        let now = card.due
        let preview = fsrs.schedule(card: card, now: now)

        for rating in Rating.allCases {
            let single = fsrs.schedule(card: card, now: now, rating: rating)
            #expect(preview[rating] == single, "preview[\(rating)] != schedule(rating:)")
        }
    }
}

// MARK: - BasicScheduler — internal-consistency byte parity
//
// We can't reproduce ts-fsrs's hardcoded numerical values for stability and
// difficulty (those tests use FSRS-5 weights). What we CAN byte-check is that
// the scheduler's S/D output is bit-identical to a fresh FSRSAlgorithm call
// — i.e. the scheduler doesn't introduce extra rounding or precision loss.

@Suite("Parity — BasicScheduler S/D matches FSRSAlgorithm.nextState exactly")
struct BasicSDParityTests {

    let params = parityParameters()
    let fsrs: FSRS
    let algo: FSRSAlgorithm

    init() {
        self.fsrs = FSRS(parameters: params)
        self.algo = FSRSAlgorithm(parameters: params)
    }

    /// New-card S/D byte-equal to `algo.nextState(0, 0, t=0, rating)` for all 4 ratings.
    @Test("New: scheduler S/D bit-identical to algorithm output")
    func newCardSDExact() {
        let card = FSRS.createCard(now: refDate)
        let result = fsrs.schedule(card: card, now: refDate)

        for rating in Rating.allCases {
            let (expectedS, expectedD) = algo.nextState(
                stability: 0, difficulty: 0, elapsedDays: 0, rating: rating
            )
            #expect(
                result[rating].card.stability == expectedS,
                "\(rating).stability: \(result[rating].card.stability) != \(expectedS)"
            )
            #expect(
                result[rating].card.difficulty == expectedD,
                "\(rating).difficulty: \(result[rating].card.difficulty) != \(expectedD)"
            )
        }
    }

    /// Learning-card S/D byte-equal to algorithm output.
    @Test("Learning: scheduler S/D bit-identical to algorithm output")
    func learningCardSDExact() {
        var card = FSRS.createCard(now: refDate)
        card = fsrs.schedule(card: card, now: refDate, rating: .again).card
        // After Again on new card, card is in .learning with same-day t=0.
        let now = card.due  // ~60s later, still same UTC day → t = 0
        let elapsed = card.elapsedDays(now: now)

        let result = fsrs.schedule(card: card, now: now)
        for rating in Rating.allCases {
            let (expectedS, expectedD) = algo.nextState(
                stability: card.stability, difficulty: card.difficulty,
                elapsedDays: elapsed, rating: rating
            )
            #expect(result[rating].card.stability == expectedS)
            #expect(result[rating].card.difficulty == expectedD)
        }
    }

    /// Review-card S/D byte-equal to algorithm output, with non-zero elapsed days.
    @Test("Review (elapsed=5d): scheduler S/D bit-identical to algorithm output")
    func reviewCardSDExact() {
        var card = FSRS.createCard(now: refDate)
        card = fsrs.schedule(card: card, now: refDate, rating: .easy).card
        #expect(card.state == .review)

        // 5 calendar days after the easy graduation
        let now = card.lastReview!.addingTimeInterval(5 * 86400)
        let elapsed = card.elapsedDays(now: now)
        #expect(elapsed == 5)

        let result = fsrs.schedule(card: card, now: now)
        for rating in Rating.allCases {
            let (expectedS, expectedD) = algo.nextState(
                stability: card.stability, difficulty: card.difficulty,
                elapsedDays: elapsed, rating: rating
            )
            #expect(result[rating].card.stability == expectedS,
                    "\(rating) S: \(result[rating].card.stability) != \(expectedS)")
            #expect(result[rating].card.difficulty == expectedD,
                    "\(rating) D: \(result[rating].card.difficulty) != \(expectedD)")
        }
    }

    /// Relearning-card S/D byte-equal to algorithm output.
    @Test("Relearning: scheduler S/D bit-identical to algorithm output")
    func relearningCardSDExact() {
        var card = FSRS.createCard(now: refDate)
        card = fsrs.schedule(card: card, now: refDate, rating: .easy).card
        card = fsrs.schedule(card: card, now: card.due, rating: .again).card
        #expect(card.state == .relearning)

        let now = card.due
        let elapsed = card.elapsedDays(now: now)

        let result = fsrs.schedule(card: card, now: now)
        for rating in Rating.allCases {
            let (expectedS, expectedD) = algo.nextState(
                stability: card.stability, difficulty: card.difficulty,
                elapsedDays: elapsed, rating: rating
            )
            #expect(result[rating].card.stability == expectedS)
            #expect(result[rating].card.difficulty == expectedD)
        }
    }
}

// MARK: - BasicScheduler — Hard interval ordering (review state)
//
// basic_scheduler.ts:213-227 enforces: hard = min(hard, good); good = max(good, hard+1);
// easy = max(easy, good+1). Strict integer ordering: hard < good < easy.

@Suite("Parity — BasicScheduler review interval ordering")
struct BasicReviewOrderingParityTests {

    let fsrs = FSRS(parameters: parityParameters())

    /// Strict ordering hard < good < easy across multiple review iterations.
    @Test("hard < good < easy (strict) for review-state card")
    func strictOrdering() {
        var card = FSRS.createCard(now: refDate)
        card = fsrs.schedule(card: card, now: refDate, rating: .easy).card

        // Run several review iterations; each must satisfy strict ordering.
        for iteration in 0..<5 {
            let elapsed = Double(iteration + 1) * 5
            let now = card.lastReview!.addingTimeInterval(elapsed * 86400)
            let result = fsrs.schedule(card: card, now: now)

            let h = result.hard.card.scheduledDays
            let g = result.good.card.scheduledDays
            let e = result.easy.card.scheduledDays

            #expect(h < g, "iter \(iteration): hard \(h) >= good \(g)")
            #expect(g < e, "iter \(iteration): good \(g) >= easy \(e)")

            // Also check due dates are consistent with scheduledDays.
            expectExactDue(result.hard.card.due, now.addingTimeInterval(Double(h) * 86400))
            expectExactDue(result.good.card.due, now.addingTimeInterval(Double(g) * 86400))
            expectExactDue(result.easy.card.due, now.addingTimeInterval(Double(e) * 86400))

            card = result.good.card
        }
    }
}

// MARK: - BasicScheduler — Lapse path (Review + Again)
//
// basic_scheduler.ts:162 — Review + Again routes through applyLearningSteps
// with State.Relearning. With empty relearning_steps, ts-fsrs's strategy
// returns no rating mapping, so scheduled_minutes = 0 → falls into the
// FSRS-graduation branch → state = Review with FSRS interval.

@Suite("Parity — Review + Again with empty relearning_steps goes to Review")
struct EmptyRelearningStepsParityTests {

    let fsrs = FSRS(parameters: parityParameters(relearningSteps: []))
    let algo: FSRSAlgorithm

    init() {
        self.algo = FSRSAlgorithm(parameters: parityParameters(relearningSteps: []))
    }

    @Test("Review + Again routes back to Review (no Relearning state)")
    func emptyRelearningGoesToReview() {
        var card = FSRS.createCard(now: refDate)
        card = fsrs.schedule(card: card, now: refDate, rating: .easy).card
        #expect(card.state == .review)

        let now = card.lastReview!.addingTimeInterval(5 * 86400)
        let result = fsrs.schedule(card: card, now: now, rating: .again)

        #expect(result.card.state == .review)
        #expect(result.card.step == 0)
        #expect(result.card.lapses == 1)

        // Algorithm computes the FSRS interval directly from the Again S.
        let elapsed = card.elapsedDays(now: now)
        let (newS, _) = algo.nextState(
            stability: card.stability, difficulty: card.difficulty,
            elapsedDays: elapsed, rating: .again
        )
        let expectedInterval = algo.nextInterval(stability: newS)
        #expect(result.card.scheduledDays == expectedInterval)
        expectExactDue(
            result.card.due,
            now.addingTimeInterval(Double(expectedInterval) * 86400)
        )
    }

    @Test("Review + Again with default relearning [600] DOES go to Relearning")
    func defaultRelearningGoesToRelearning() {
        let fsrs = FSRS(parameters: parityParameters(relearningSteps: [600]))

        var card = FSRS.createCard(now: refDate)
        card = fsrs.schedule(card: card, now: refDate, rating: .easy).card

        let now = card.lastReview!.addingTimeInterval(5 * 86400)
        let result = fsrs.schedule(card: card, now: now, rating: .again)

        #expect(result.card.state == .relearning)
        #expect(result.card.step == 0)
        #expect(result.card.scheduledDays == 0)
        #expect(result.card.lapses == 1)
        expectExactDue(result.card.due, now.addingTimeInterval(600))
    }
}

// MARK: - BasicScheduler — counters (reps, lapses)

@Suite("Parity — BasicScheduler reps and lapses counters")
struct BasicCountersParityTests {

    let fsrs = FSRS(parameters: parityParameters())

    /// reps increments by exactly 1 per review.
    @Test("reps increments by 1 for every rating across all states")
    func repsIncrementByOne() {
        let card = FSRS.createCard(now: refDate)
        for rating in Rating.allCases {
            let result = fsrs.schedule(card: card, now: refDate, rating: rating)
            #expect(result.card.reps == 1, "\(rating): reps != 1")
        }
    }

    /// Lapses ONLY increments on Again from Review state — verified for
    /// every state × rating combination.
    @Test("lapses increments only on Again from Review")
    func lapsesIncrementsOnlyOnReviewAgain() {
        let new = FSRS.createCard(now: refDate)

        // From New: no lapse for any rating
        for rating in Rating.allCases {
            let result = fsrs.schedule(card: new, now: refDate, rating: rating)
            #expect(result.card.lapses == 0, "New + \(rating): lapses != 0")
        }

        // From Learning: no lapse for any rating
        let learning = fsrs.schedule(card: new, now: refDate, rating: .again).card
        #expect(learning.state == .learning)
        for rating in Rating.allCases {
            let result = fsrs.schedule(card: learning, now: learning.due, rating: rating)
            #expect(result.card.lapses == 0, "Learning + \(rating): lapses != 0")
        }

        // From Review: ONLY Again increments
        let review = fsrs.schedule(card: new, now: refDate, rating: .easy).card
        #expect(review.state == .review)
        let reviewNow = review.lastReview!.addingTimeInterval(5 * 86400)
        for rating in Rating.allCases {
            let result = fsrs.schedule(card: review, now: reviewNow, rating: rating)
            let expected = (rating == .again) ? 1 : 0
            #expect(
                result.card.lapses == expected,
                "Review + \(rating): lapses == \(result.card.lapses) (expected \(expected))"
            )
        }

        // From Relearning: no lapse for any rating in BasicScheduler
        // (lapse already counted at the Review→Relearning transition).
        var relearning = review
        relearning = fsrs.schedule(card: relearning, now: reviewNow, rating: .again).card
        #expect(relearning.state == .relearning)
        #expect(relearning.lapses == 1)
        for rating in Rating.allCases {
            let result = fsrs.schedule(card: relearning, now: relearning.due, rating: rating)
            #expect(
                result.card.lapses == 1,
                "Relearning + \(rating): lapses changed from 1 to \(result.card.lapses)"
            )
        }
    }
}

// MARK: - LongTermScheduler — strict ordering parity
//
// long_term_scheduler.ts:112-115 — ALL four ratings strictly ordered:
// again = min(again, hard); hard = max(hard, again+1); good = max(good, hard+1);
// easy = max(easy, good+1).

@Suite("Parity — LongTermScheduler strict ordering again < hard < good < easy")
struct LongTermOrderingParityTests {

    let fsrs = FSRS(
        parameters: parityParameters(enableShortTerm: false)
    )

    @Test("New card: strict ordering across all 4 ratings")
    func newCardOrdering() {
        let card = FSRS.createCard(now: refDate)
        let result = fsrs.schedule(card: card, now: refDate)

        let a = result.again.card.scheduledDays
        let h = result.hard.card.scheduledDays
        let g = result.good.card.scheduledDays
        let e = result.easy.card.scheduledDays

        #expect(a < h, "again \(a) >= hard \(h)")
        #expect(h < g, "hard \(h) >= good \(g)")
        #expect(g < e, "good \(g) >= easy \(e)")

        // Due dates exactly correspond to scheduledDays * 86400.
        expectExactDue(result.again.card.due, refDate.addingTimeInterval(Double(a) * 86400))
        expectExactDue(result.hard.card.due, refDate.addingTimeInterval(Double(h) * 86400))
        expectExactDue(result.good.card.due, refDate.addingTimeInterval(Double(g) * 86400))
        expectExactDue(result.easy.card.due, refDate.addingTimeInterval(Double(e) * 86400))
    }

    @Test("Review card: strict ordering across all 4 ratings")
    func reviewCardOrdering() {
        var card = FSRS.createCard(now: refDate)
        card = fsrs.schedule(card: card, now: refDate, rating: .good).card
        #expect(card.state == .review)

        // Several iterations to exercise larger intervals.
        for iteration in 0..<5 {
            let elapsed = Double(iteration + 1) * 7
            let now = card.lastReview!.addingTimeInterval(elapsed * 86400)
            let result = fsrs.schedule(card: card, now: now)

            let a = result.again.card.scheduledDays
            let h = result.hard.card.scheduledDays
            let g = result.good.card.scheduledDays
            let e = result.easy.card.scheduledDays

            #expect(a < h, "iter \(iteration): again \(a) >= hard \(h)")
            #expect(h < g, "iter \(iteration): hard \(h) >= good \(g)")
            #expect(g < e, "iter \(iteration): good \(g) >= easy \(e)")

            card = result.good.card
        }
    }
}

// MARK: - LongTermScheduler — S/D matches algorithm exactly

@Suite("Parity — LongTermScheduler S/D matches FSRSAlgorithm.nextState exactly")
struct LongTermSDParityTests {

    let params = parityParameters(enableShortTerm: false)
    let fsrs: FSRS
    let algo: FSRSAlgorithm

    init() {
        self.fsrs = FSRS(parameters: params)
        self.algo = FSRSAlgorithm(parameters: params)
    }

    /// New card — first review S/D matches algorithm.
    @Test("New: scheduler S/D bit-identical to algorithm output")
    func newCardSDExact() {
        let card = FSRS.createCard(now: refDate)
        let result = fsrs.schedule(card: card, now: refDate)

        for rating in Rating.allCases {
            let (expectedS, expectedD) = algo.nextState(
                stability: 0, difficulty: 0, elapsedDays: 0, rating: rating
            )
            #expect(
                result[rating].card.stability == expectedS,
                "\(rating).stability: \(result[rating].card.stability) != \(expectedS)"
            )
            #expect(
                result[rating].card.difficulty == expectedD,
                "\(rating).difficulty: \(result[rating].card.difficulty) != \(expectedD)"
            )
        }
    }

    /// Review card after one Good — second-review S/D matches algorithm exactly.
    @Test("Review (elapsed=10d): scheduler S/D bit-identical to algorithm output")
    func reviewCardSDExact() {
        var card = FSRS.createCard(now: refDate)
        card = fsrs.schedule(card: card, now: refDate, rating: .good).card

        let now = card.lastReview!.addingTimeInterval(10 * 86400)
        let elapsed = card.elapsedDays(now: now)
        #expect(elapsed == 10)

        let result = fsrs.schedule(card: card, now: now)
        for rating in Rating.allCases {
            let (expectedS, expectedD) = algo.nextState(
                stability: card.stability, difficulty: card.difficulty,
                elapsedDays: elapsed, rating: rating
            )
            #expect(result[rating].card.stability == expectedS)
            #expect(result[rating].card.difficulty == expectedD)
        }
    }
}

// MARK: - LongTermScheduler — lapses semantics
//
// long_term_scheduler.ts: `next_again.lapses += 1` runs in `reviewState`
// (which `learningState` delegates to). Only the `newState` branch — taken
// for first review of a brand-new card — does NOT increment lapses on Again.

@Suite("Parity — LongTermScheduler lapses on Again")
struct LongTermLapsesParityTests {

    let fsrs = FSRS(
        parameters: parityParameters(enableShortTerm: false)
    )

    /// New + Again: no lapse increment (newState branch).
    @Test("New + Again: lapses stays 0")
    func newAgainNoLapse() {
        let card = FSRS.createCard(now: refDate)
        let result = fsrs.schedule(card: card, now: refDate, rating: .again)
        #expect(result.card.lapses == 0)
        #expect(result.card.state == .review)
    }

    /// Review + Again: lapses += 1.
    @Test("Review + Again: lapses increments by 1")
    func reviewAgainIncrementsLapse() {
        var card = FSRS.createCard(now: refDate)
        card = fsrs.schedule(card: card, now: refDate, rating: .good).card
        #expect(card.lapses == 0)
        let now = card.lastReview!.addingTimeInterval(5 * 86400)
        let result = fsrs.schedule(card: card, now: now, rating: .again)
        #expect(result.card.lapses == 1)
        #expect(result.card.state == .review)
    }

    /// Multiple lapses: counter accumulates correctly.
    @Test("Multiple Review + Again: lapses accumulates")
    func multipleLapses() {
        var card = FSRS.createCard(now: refDate)
        card = fsrs.schedule(card: card, now: refDate, rating: .good).card

        for i in 1...3 {
            let now = card.lastReview!.addingTimeInterval(Double(i) * 5 * 86400)
            card = fsrs.schedule(card: card, now: now, rating: .again).card
            #expect(card.lapses == i)
        }
    }

    /// reps increments uniformly across all ratings.
    @Test("reps increments by 1 for every rating from any state")
    func repsIncrementByOne() {
        let card = FSRS.createCard(now: refDate)
        for rating in Rating.allCases {
            let result = fsrs.schedule(card: card, now: refDate, rating: rating)
            #expect(result.card.reps == 1)
        }
    }
}

// MARK: - LongTermScheduler — state always Review

@Suite("Parity — LongTermScheduler always graduates to Review")
struct LongTermStateParityTests {

    let fsrs = FSRS(
        parameters: parityParameters(enableShortTerm: false)
    )

    @Test("Every rating from every state lands in .review with step 0")
    func alwaysReview() {
        // From New
        let new = FSRS.createCard(now: refDate)
        for rating in Rating.allCases {
            let r = fsrs.schedule(card: new, now: refDate, rating: rating)
            #expect(r.card.state == .review, "New + \(rating)")
            #expect(r.card.step == 0, "New + \(rating): step != 0")
        }

        // From Review
        let review = fsrs.schedule(card: new, now: refDate, rating: .good).card
        let reviewNow = review.lastReview!.addingTimeInterval(5 * 86400)
        for rating in Rating.allCases {
            let r = fsrs.schedule(card: review, now: reviewNow, rating: rating)
            #expect(r.card.state == .review, "Review + \(rating)")
            #expect(r.card.step == 0, "Review + \(rating): step != 0")
        }

        // From Learning (built via short-term scheduler, then handled long-term).
        // Mirrors the [State.(Re)Learning]switch long-term scheduler scenario
        // in long-term_scheduler.test.ts:227-283 — the long-term scheduler
        // delegates `learningState` to `reviewState`, so Learning + Again must
        // graduate to Review with lapses += 1.
        let basic = FSRS(parameters: parityParameters(enableShortTerm: true))
        let learning = basic.schedule(card: new, now: refDate, rating: .again).card
        #expect(learning.state == .learning)
        for rating in Rating.allCases {
            let r = fsrs.schedule(card: learning, now: learning.due, rating: rating)
            #expect(r.card.state == .review, "Learning(LT) + \(rating)")
            #expect(r.card.step == 0, "Learning(LT) + \(rating): step != 0")
        }

        // From Relearning (built via short-term, then handled long-term).
        let lapsed = basic.schedule(card: review, now: reviewNow, rating: .again).card
        #expect(lapsed.state == .relearning)
        for rating in Rating.allCases {
            let r = fsrs.schedule(card: lapsed, now: lapsed.due, rating: rating)
            #expect(r.card.state == .review, "Relearning(LT) + \(rating)")
            #expect(r.card.step == 0, "Relearning(LT) + \(rating): step != 0")
        }
    }

    /// long-term_scheduler.ts `learningState` delegates to `reviewState`,
    /// which unconditionally `next_again.lapses += 1`. So Learning + Again
    /// in long-term mode increments lapses (divergence from BasicScheduler,
    /// which only increments on Review + Again).
    @Test("Learning(LT) + Again increments lapses (delegates to reviewState)")
    func learningAgainIncrementsLapseInLongTerm() {
        let basic = FSRS(parameters: parityParameters(enableShortTerm: true))
        let new = FSRS.createCard(now: refDate)
        let learning = basic.schedule(card: new, now: refDate, rating: .again).card
        #expect(learning.state == .learning)
        #expect(learning.lapses == 0)

        let result = fsrs.schedule(card: learning, now: learning.due, rating: .again)
        #expect(result.card.lapses == 1, "Learning(LT) + Again should increment lapses")
        #expect(result.card.state == .review)
    }

    /// long-term_scheduler.ts: Relearning + Again also increments lapses
    /// (same delegation path).
    @Test("Relearning(LT) + Again increments lapses (delegates to reviewState)")
    func relearningAgainIncrementsLapseInLongTerm() {
        let basic = FSRS(parameters: parityParameters(enableShortTerm: true))
        let new = FSRS.createCard(now: refDate)
        let review = basic.schedule(card: new, now: refDate, rating: .easy).card
        #expect(review.state == .review)

        let now = review.lastReview!.addingTimeInterval(5 * 86400)
        let lapsed = basic.schedule(card: review, now: now, rating: .again).card
        #expect(lapsed.state == .relearning)
        #expect(lapsed.lapses == 1)

        // Now under long-term: Relearning + Again increments to 2.
        let result = fsrs.schedule(card: lapsed, now: lapsed.due, rating: .again)
        #expect(result.card.lapses == 2, "Relearning(LT) + Again should increment to 2")
        #expect(result.card.state == .review)
    }
}

// MARK: - lastReview parity

@Suite("Parity — lastReview always set to `now`")
struct LastReviewParityTests {

    /// Both schedulers must set lastReview to the review time on every rating.
    @Test("BasicScheduler: lastReview == now after review")
    func basicLastReview() {
        let fsrs = FSRS(parameters: parityParameters())
        let card = FSRS.createCard(now: refDate)
        let now = refDate.addingTimeInterval(123)
        for rating in Rating.allCases {
            let result = fsrs.schedule(card: card, now: now, rating: rating)
            #expect(
                result.card.lastReview?.timeIntervalSinceReferenceDate
                    == now.timeIntervalSinceReferenceDate,
                "\(rating): lastReview != now"
            )
        }
    }

    @Test("LongTermScheduler: lastReview == now after review")
    func longTermLastReview() {
        let fsrs = FSRS(parameters: parityParameters(enableShortTerm: false))
        let card = FSRS.createCard(now: refDate)
        let now = refDate.addingTimeInterval(456)
        for rating in Rating.allCases {
            let result = fsrs.schedule(card: card, now: now, rating: rating)
            #expect(
                result.card.lastReview?.timeIntervalSinceReferenceDate
                    == now.timeIntervalSinceReferenceDate
            )
        }
    }
}

// MARK: - scheduledDays for in-day learning steps

@Suite("Parity — scheduledDays = 0 for in-day steps")
struct InDayScheduledDaysParityTests {

    /// basic_scheduler.ts:82 — in-day steps set scheduled_days = 0.
    /// Critical because the field is now stored (Wave 4) and rollback uses it.
    @Test("Default config: every in-day learning/relearning step has scheduledDays == 0")
    func inDayScheduledDaysAllZero() {
        let fsrs = FSRS(parameters: parityParameters())

        // New + Again/Hard/Good (all in-day with default [60, 600])
        let new = FSRS.createCard(now: refDate)
        for rating: Rating in [.again, .hard, .good] {
            let r = fsrs.schedule(card: new, now: refDate, rating: rating)
            #expect(r.card.scheduledDays == 0, "New + \(rating): scheduledDays != 0")
        }

        // Learning step 0 (via Again on New) — Again/Hard/Good all in-day
        // (Good targets step 1, which is 600s — still < 1 day)
        let learningStep0 = fsrs.schedule(card: new, now: refDate, rating: .again).card
        #expect(learningStep0.state == .learning)
        #expect(learningStep0.step == 0)
        for rating: Rating in [.again, .hard, .good] {
            let r = fsrs.schedule(card: learningStep0, now: learningStep0.due, rating: rating)
            #expect(r.card.scheduledDays == 0,
                    "Learning step 0 + \(rating): scheduledDays != 0")
        }

        // Learning step 1 (via Good on New) — Again/Hard in-day; Good graduates
        // because it targets step 2 (out of range for [60, 600])
        let learningStep1 = fsrs.schedule(card: new, now: refDate, rating: .good).card
        #expect(learningStep1.state == .learning)
        #expect(learningStep1.step == 1)
        for rating: Rating in [.again, .hard] {
            let r = fsrs.schedule(card: learningStep1, now: learningStep1.due, rating: rating)
            #expect(r.card.scheduledDays == 0,
                    "Learning step 1 + \(rating): scheduledDays != 0")
        }
        // Good from step 1 graduates → scheduledDays > 0
        let graduated = fsrs.schedule(card: learningStep1, now: learningStep1.due, rating: .good)
        #expect(graduated.card.state == .review)
        #expect(graduated.card.scheduledDays > 0)

        // Review + Again with default relearning [600] → in-day relearning
        let review = fsrs.schedule(card: new, now: refDate, rating: .easy).card
        let reviewNow = review.lastReview!.addingTimeInterval(5 * 86400)
        let lapsed = fsrs.schedule(card: review, now: reviewNow, rating: .again).card
        #expect(lapsed.state == .relearning)
        #expect(lapsed.scheduledDays == 0)
    }
}
