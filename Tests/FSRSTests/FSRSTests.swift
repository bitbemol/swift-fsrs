import Foundation
import Testing

@testable import FSRS

// MARK: - Test Helpers

/// Asserts two Doubles are equal within a tolerance.
func expectApprox(
    _ actual: Double,
    _ expected: Double,
    tolerance: Double = 0.01,
    _ comment: Comment? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(
        abs(actual - expected) < tolerance,
        "\(actual) ≠ \(expected) (±\(tolerance))",
        sourceLocation: sourceLocation
    )
}

/// A fixed reference date for deterministic tests.
let refDate = Date(timeIntervalSinceReferenceDate: 800_000_000)  // 2026-05-09

/// Creates a date `days` after the reference date.
func dateAfter(days: Double) -> Date {
    refDate.addingTimeInterval(days * 86400.0)
}

// MARK: - Algorithm Tests

@Suite("FSRSAlgorithm — Forgetting Curve")
struct ForgettingCurveTests {
    let algo = FSRSAlgorithm(parameters: Parameters())

    @Test("R(0, S) = 1.0 — just reviewed")
    func retrievabilityAtZero() {
        expectApprox(algo.forgettingCurve(elapsedDays: 0, stability: 1.0), 1.0)
        expectApprox(algo.forgettingCurve(elapsedDays: 0, stability: 10.0), 1.0)
    }

    @Test("R(S, S) ≈ 0.9 — by construction")
    func retrievabilityAtStability() {
        for s in [0.5, 1.0, 2.3065, 10.0, 100.0] {
            expectApprox(algo.forgettingCurve(elapsedDays: s, stability: s), 0.9, tolerance: 0.001)
        }
    }

    @Test("R decreases over time")
    func retrievabilityDecreases() {
        let s = 5.0
        var prev = 1.0
        for t in stride(from: 1.0, through: 30.0, by: 1.0) {
            let r = algo.forgettingCurve(elapsedDays: t, stability: s)
            #expect(r < prev, "R should decrease: R(\(t)) = \(r) >= R(\(t - 1)) = \(prev)")
            prev = r
        }
    }

    @Test("R(t, S) specific value check")
    func specificValue() {
        // R(5, 2.3065) ≈ 0.839
        let r = algo.forgettingCurve(elapsedDays: 5.0, stability: 2.3065)
        expectApprox(r, 0.839, tolerance: 0.01)
    }
}

@Suite("FSRSAlgorithm — Initial State")
struct InitialStateTests {
    let algo = FSRSAlgorithm(parameters: Parameters())

    @Test("Initial stability matches w[0]–w[3]")
    func initialStability() {
        let w = Weights.default
        expectApprox(algo.initialStability(rating: .again), w[0])
        expectApprox(algo.initialStability(rating: .hard), w[1])
        expectApprox(algo.initialStability(rating: .good), w[2])
        expectApprox(algo.initialStability(rating: .easy), w[3])
    }

    @Test("Initial stability ordering: Again < Hard < Good < Easy")
    func initialStabilityOrder() {
        let sAgain = algo.initialStability(rating: .again)
        let sHard = algo.initialStability(rating: .hard)
        let sGood = algo.initialStability(rating: .good)
        let sEasy = algo.initialStability(rating: .easy)
        #expect(sAgain < sHard)
        #expect(sHard < sGood)
        #expect(sGood < sEasy)
    }

    @Test("Initial difficulty ordering: Again > Hard > Good > Easy")
    func initialDifficultyOrder() {
        let dAgain = algo.initialDifficulty(rating: .again)
        let dHard = algo.initialDifficulty(rating: .hard)
        let dGood = algo.initialDifficulty(rating: .good)
        let dEasy = algo.initialDifficulty(rating: .easy)
        #expect(dAgain > dHard)
        #expect(dHard > dGood)
        #expect(dGood > dEasy)
    }

    @Test("D₀(Again) ≈ w[4]")
    func initialDifficultyAgain() {
        expectApprox(algo.initialDifficulty(rating: .again), 6.4133, tolerance: 0.01)
    }

    @Test("D₀(Easy) clamped to 1.0")
    func initialDifficultyEasyClamped() {
        // The formula gives a negative value for Easy, clamped to 1.0
        expectApprox(algo.initialDifficulty(rating: .easy), 1.0)
    }
}

@Suite("FSRSAlgorithm — Next Difficulty")
struct NextDifficultyTests {
    let algo = FSRSAlgorithm(parameters: Parameters())

    @Test("Again increases difficulty")
    func againIncreases() {
        let d = 5.0
        let newD = algo.nextDifficulty(current: d, rating: .again)
        #expect(newD > d)
    }

    @Test("Easy decreases difficulty")
    func easyDecreases() {
        let d = 5.0
        let newD = algo.nextDifficulty(current: d, rating: .easy)
        #expect(newD < d)
    }

    @Test("Good keeps difficulty nearly the same")
    func goodStable() {
        let d = 5.0
        let newD = algo.nextDifficulty(current: d, rating: .good)
        expectApprox(newD, d, tolerance: 0.1)
    }

    @Test("Difficulty stays within [1, 10]")
    func clampedBounds() {
        // Push high
        var d = 9.5
        for _ in 0..<20 {
            d = algo.nextDifficulty(current: d, rating: .again)
        }
        #expect(d <= 10.0)

        // Push low
        d = 1.5
        for _ in 0..<20 {
            d = algo.nextDifficulty(current: d, rating: .easy)
        }
        #expect(d >= 1.0)
    }
}

@Suite("FSRSAlgorithm — Recall Stability")
struct RecallStabilityTests {
    let algo = FSRSAlgorithm(parameters: Parameters())

    @Test("Recall increases stability")
    func recallIncreasesStability() {
        let d = 5.0, s = 10.0
        let r = algo.forgettingCurve(elapsedDays: 10, stability: s)
        let newS = algo.nextRecallStability(d: d, s: s, r: r, rating: .good)
        #expect(newS > s)
    }

    @Test("Hard penalty reduces stability gain")
    func hardPenalty() {
        let d = 5.0, s = 10.0
        let r = algo.forgettingCurve(elapsedDays: 10, stability: s)
        let hardS = algo.nextRecallStability(d: d, s: s, r: r, rating: .hard)
        let goodS = algo.nextRecallStability(d: d, s: s, r: r, rating: .good)
        #expect(hardS < goodS)
    }

    @Test("Easy bonus increases stability gain")
    func easyBonus() {
        let d = 5.0, s = 10.0
        let r = algo.forgettingCurve(elapsedDays: 10, stability: s)
        let goodS = algo.nextRecallStability(d: d, s: s, r: r, rating: .good)
        let easyS = algo.nextRecallStability(d: d, s: s, r: r, rating: .easy)
        #expect(easyS > goodS)
    }

    @Test("Lower R gives bigger stability gain (spacing effect)")
    func spacingEffect() {
        let d = 5.0, s = 10.0
        let rHigh = algo.forgettingCurve(elapsedDays: 5, stability: s)
        let rLow = algo.forgettingCurve(elapsedDays: 15, stability: s)
        let sHigh = algo.nextRecallStability(d: d, s: s, r: rHigh, rating: .good)
        let sLow = algo.nextRecallStability(d: d, s: s, r: rLow, rating: .good)
        // Reviewing when R is lower (more forgotten) gives more stability gain
        #expect(sLow > sHigh)
    }
}

@Suite("FSRSAlgorithm — Forget Stability")
struct ForgetStabilityTests {
    let algo = FSRSAlgorithm(parameters: Parameters())

    @Test("Forget drastically reduces stability")
    func forgetReduces() {
        let d = 5.0, s = 20.0
        let r = algo.forgettingCurve(elapsedDays: 20, stability: s)
        let newS = algo.nextForgetStability(d: d, s: s, r: r)
        #expect(newS < s)
        #expect(newS < s * 0.5, "Post-lapse stability should be much less than pre-lapse")
    }
}

@Suite("FSRSAlgorithm — Short-Term Stability")
struct ShortTermStabilityTests {
    let algo = FSRSAlgorithm(parameters: Parameters())

    @Test("Hard/Good/Easy can only increase stability (sinc ≥ 1)")
    func noDecrease() {
        for s in [0.5, 2.0, 10.0, 50.0] {
            for rating: Rating in [.hard, .good, .easy] {
                let newS = algo.nextShortTermStability(s: s, rating: rating)
                #expect(
                    newS >= s,
                    "Short-term \(rating) should not decrease S from \(s), got \(newS)"
                )
            }
        }
    }

    @Test("Again can decrease stability")
    func againDecreases() {
        let newS = algo.nextShortTermStability(s: 5.0, rating: .again)
        #expect(newS < 5.0)
    }

    @Test("Easy gives higher stability than Good")
    func easyGreaterThanGood() {
        let s = 5.0
        let goodS = algo.nextShortTermStability(s: s, rating: .good)
        let easyS = algo.nextShortTermStability(s: s, rating: .easy)
        #expect(easyS > goodS)
    }
}

@Suite("FSRSAlgorithm — Interval Calculation")
struct IntervalTests {
    @Test("With 0.9 retention, interval ≈ stability")
    func intervalEqualsStability() {
        let algo = FSRSAlgorithm(parameters: Parameters(requestRetention: 0.9))
        // intervalModifier = 1.0 when retention = 0.9
        #expect(algo.nextInterval(stability: 1.0) == 1)
        #expect(algo.nextInterval(stability: 2.3065) == 2)
        #expect(algo.nextInterval(stability: 8.2956) == 8)
        #expect(algo.nextInterval(stability: 30.0) == 30)
    }

    @Test("Lower retention produces shorter intervals")
    func lowerRetention() {
        let algo85 = FSRSAlgorithm(parameters: Parameters(requestRetention: 0.85))
        let algo90 = FSRSAlgorithm(parameters: Parameters(requestRetention: 0.90))
        let s = 20.0
        #expect(algo85.nextInterval(stability: s) > algo90.nextInterval(stability: s))
    }

    @Test("Higher retention produces longer intervals")
    func higherRetention() {
        let algo90 = FSRSAlgorithm(parameters: Parameters(requestRetention: 0.90))
        let algo95 = FSRSAlgorithm(parameters: Parameters(requestRetention: 0.95))
        let s = 20.0
        #expect(algo95.nextInterval(stability: s) < algo90.nextInterval(stability: s))
    }

    @Test("Interval clamped to [1, maximumInterval]")
    func clamped() {
        let algo = FSRSAlgorithm(parameters: Parameters(maximumInterval: 100))
        #expect(algo.nextInterval(stability: 0.01) == 1)
        #expect(algo.nextInterval(stability: 200.0) == 100)
    }
}

@Suite("FSRSAlgorithm — State Dispatch")
struct StateDispatchTests {
    let algo = FSRSAlgorithm(parameters: Parameters())

    @Test("New card initializes S and D")
    func newCard() {
        let (s, d) = algo.nextState(stability: 0, difficulty: 0, elapsedDays: 0, rating: .good)
        expectApprox(s, algo.initialStability(rating: .good))
        expectApprox(d, algo.initialDifficulty(rating: .good))
    }

    @Test("Same-day review uses short-term formula")
    func sameDay() {
        let s = 5.0, d = 5.0
        let (newS, _) = algo.nextState(stability: s, difficulty: d, elapsedDays: 0, rating: .good)
        let expected = algo.nextShortTermStability(s: s, rating: .good)
        expectApprox(newS, expected)
    }

    @Test("Lapse uses forget formula")
    func lapse() {
        let s = 20.0, d = 5.0, t = 20
        let (newS, _) = algo.nextState(stability: s, difficulty: d, elapsedDays: t, rating: .again)
        #expect(newS < s)
    }

    @Test("Recall uses recall formula")
    func recall() {
        let s = 10.0, d = 5.0, t = 10
        let (newS, _) = algo.nextState(stability: s, difficulty: d, elapsedDays: t, rating: .good)
        #expect(newS > s)
    }
}

// MARK: - LongTermScheduler Tests

@Suite("LongTermScheduler")
struct LongTermSchedulerTests {
    let fsrs = FSRS(parameters: Parameters(enableShortTerm: false))

    @Test("New card — all ratings go to Review state")
    func newToReview() {
        let card = FSRS.createCard(now: refDate)
        let result = fsrs.schedule(card: card, now: refDate)

        for rating in Rating.allCases {
            #expect(result[rating].card.state == .review)
            #expect(result[rating].card.step == 0)
        }
    }

    @Test("Interval ordering: again < hard < good < easy")
    func intervalOrdering() {
        let card = FSRS.createCard(now: refDate)
        let result = fsrs.schedule(card: card, now: refDate)

        let againDays = result.again.card.scheduledDays
        let hardDays = result.hard.card.scheduledDays
        let goodDays = result.good.card.scheduledDays
        let easyDays = result.easy.card.scheduledDays

        #expect(againDays < hardDays)
        #expect(hardDays < goodDays)
        #expect(goodDays < easyDays)
    }

    @Test("Review card — stability increases for Good")
    func reviewGoodIncreasesStability() {
        var card = FSRS.createCard(now: refDate)
        // First review: Good
        card = fsrs.schedule(card: card, now: refDate, rating: .good).card
        let s1 = card.stability
        // Second review at due date: Good
        card = fsrs.schedule(card: card, now: card.due, rating: .good).card
        #expect(card.stability > s1)
    }

    @Test("Review card — Again increments lapses")
    func againIncrementsLapses() {
        var card = FSRS.createCard(now: refDate)
        card = fsrs.schedule(card: card, now: refDate, rating: .good).card
        #expect(card.lapses == 0)
        card = fsrs.schedule(card: card, now: card.due, rating: .again).card
        #expect(card.lapses == 1)
    }

    @Test("First review Again does not increment lapses")
    func firstAgainNoLapse() {
        let card = FSRS.createCard(now: refDate)
        let result = fsrs.schedule(card: card, now: refDate, rating: .again)
        #expect(result.card.lapses == 0)
    }

    @Test("Reps increments on each review")
    func repsIncrement() {
        var card = FSRS.createCard(now: refDate)
        #expect(card.reps == 0)
        card = fsrs.schedule(card: card, now: refDate, rating: .good).card
        #expect(card.reps == 1)
        card = fsrs.schedule(card: card, now: card.due, rating: .good).card
        #expect(card.reps == 2)
    }
}

// MARK: - BasicScheduler Tests

@Suite("BasicScheduler — New Card")
struct BasicNewCardTests {
    let fsrs = FSRS()

    @Test("Again → Learning at step 0")
    func againToLearning() {
        let card = FSRS.createCard(now: refDate)
        let result = fsrs.schedule(card: card, now: refDate, rating: .again)
        #expect(result.card.state == .learning)
        #expect(result.card.step == 0)
    }

    @Test("Hard → Learning at step 0 with 6-minute `getHardInterval`")
    func hardToLearning() {
        let card = FSRS.createCard(now: refDate)
        let result = fsrs.schedule(card: card, now: refDate, rating: .hard)
        #expect(result.card.state == .learning)
        #expect(result.card.step == 0)
        // Default steps are [1m, 10m] so Hard schedules `round((1+10)/2) = 6`
        // minutes — independent of which step the card sits on.
        let expected = refDate.addingTimeInterval(360)
        expectApprox(result.card.due.timeIntervalSinceReferenceDate,
                     expected.timeIntervalSinceReferenceDate, tolerance: 1.0)
    }

    @Test("Good → Learning at step 1 (with default 2 steps)")
    func goodToStep1() {
        let card = FSRS.createCard(now: refDate)
        let result = fsrs.schedule(card: card, now: refDate, rating: .good)
        #expect(result.card.state == .learning)
        #expect(result.card.step == 1)
    }

    @Test("Easy → Review immediately")
    func easyGraduates() {
        let card = FSRS.createCard(now: refDate)
        let result = fsrs.schedule(card: card, now: refDate, rating: .easy)
        #expect(result.card.state == .review)
        #expect(result.card.step == 0)
    }

    @Test("Again due = now + 1 minute (default step)")
    func againDue() {
        let card = FSRS.createCard(now: refDate)
        let result = fsrs.schedule(card: card, now: refDate, rating: .again)
        let expected = refDate.addingTimeInterval(60)
        expectApprox(result.card.due.timeIntervalSinceReferenceDate,
                     expected.timeIntervalSinceReferenceDate, tolerance: 1.0)
    }

    @Test("Good due = now + 10 minutes (default step 1)")
    func goodDue() {
        let card = FSRS.createCard(now: refDate)
        let result = fsrs.schedule(card: card, now: refDate, rating: .good)
        let expected = refDate.addingTimeInterval(600)
        expectApprox(result.card.due.timeIntervalSinceReferenceDate,
                     expected.timeIntervalSinceReferenceDate, tolerance: 1.0)
    }

    @Test("Good with single step graduates immediately")
    func singleStepGraduates() {
        let params = Parameters(learningSteps: [60])  // only 1 step
        let fsrs = FSRS(parameters: params)
        let card = FSRS.createCard(now: refDate)
        let result = fsrs.schedule(card: card, now: refDate, rating: .good)
        // Good targets step 1, but only 1 step exists → graduate
        #expect(result.card.state == .review)
    }
}

@Suite("BasicScheduler — Learning Progression")
struct BasicLearningTests {
    let fsrs = FSRS()

    @Test("Good advances step and graduates")
    func goodAdvances() {
        var card = FSRS.createCard(now: refDate)
        // First review: Good → Learning step 1
        card = fsrs.schedule(card: card, now: refDate, rating: .good).card
        #expect(card.state == .learning)
        #expect(card.step == 1)

        // Second review: Good → step 2 >= count → graduate to Review
        card = fsrs.schedule(card: card, now: card.due, rating: .good).card
        #expect(card.state == .review)
    }

    @Test("Again resets to step 0")
    func againResets() {
        var card = FSRS.createCard(now: refDate)
        // Good → step 1
        card = fsrs.schedule(card: card, now: refDate, rating: .good).card
        #expect(card.step == 1)

        // Again → back to step 0
        card = fsrs.schedule(card: card, now: card.due, rating: .again).card
        #expect(card.step == 0)
        #expect(card.state == .learning)
    }

    @Test("Hard repeats current step with step-independent duration")
    func hardRepeats() {
        var card = FSRS.createCard(now: refDate)
        // Good → step 1
        card = fsrs.schedule(card: card, now: refDate, rating: .good).card
        #expect(card.step == 1)

        // Hard → still step 1, but the duration is the step-independent
        // `getHardInterval` (6 minutes for default [1m, 10m]) — not
        // `steps[1] = 10m`. Pre-fix bug scheduled +600s.
        let reviewAt = card.due
        card = fsrs.schedule(card: card, now: reviewAt, rating: .hard).card
        #expect(card.step == 1)
        #expect(card.state == .learning)
        let expected = reviewAt.addingTimeInterval(360)
        expectApprox(card.due.timeIntervalSinceReferenceDate,
                     expected.timeIntervalSinceReferenceDate, tolerance: 1.0)
    }

    @Test("Easy graduates from any step")
    func easyGraduates() {
        var card = FSRS.createCard(now: refDate)
        // Again → step 0
        card = fsrs.schedule(card: card, now: refDate, rating: .again).card
        #expect(card.state == .learning)

        // Easy → graduate
        card = fsrs.schedule(card: card, now: card.due, rating: .easy).card
        #expect(card.state == .review)
    }
}

@Suite("BasicScheduler — Review State")
struct BasicReviewTests {
    let fsrs = FSRS()

    @Test("Again on Review → Relearning")
    func againToRelearning() {
        var card = FSRS.createCard(now: refDate)
        // Graduate: Good → Learning → Good → Review
        card = fsrs.schedule(card: card, now: refDate, rating: .good).card
        card = fsrs.schedule(card: card, now: card.due, rating: .good).card
        #expect(card.state == .review)

        // Again → Relearning
        card = fsrs.schedule(card: card, now: card.due, rating: .again).card
        #expect(card.state == .relearning)
        #expect(card.lapses == 1)
    }

    @Test("Hard/Good/Easy on Review → stays Review")
    func staysReview() {
        var card = FSRS.createCard(now: refDate)
        card = fsrs.schedule(card: card, now: refDate, rating: .good).card
        card = fsrs.schedule(card: card, now: card.due, rating: .good).card
        #expect(card.state == .review)

        for rating: Rating in [.hard, .good, .easy] {
            let result = fsrs.schedule(card: card, now: card.due, rating: rating)
            #expect(result.card.state == .review, "\(rating) should keep Review state")
        }
    }

    @Test("Review interval ordering: hard < good < easy")
    func reviewIntervalOrder() {
        var card = FSRS.createCard(now: refDate)
        card = fsrs.schedule(card: card, now: refDate, rating: .good).card
        card = fsrs.schedule(card: card, now: card.due, rating: .good).card

        let result = fsrs.schedule(card: card, now: card.due)
        let hardDue = result.hard.card.due
        let goodDue = result.good.card.due
        let easyDue = result.easy.card.due

        #expect(hardDue < goodDue)
        #expect(goodDue < easyDue)
    }
}

@Suite("BasicScheduler — Relearning")
struct BasicRelearningTests {
    let fsrs = FSRS()

    @Test("Again on Relearning resets to step 0")
    func againResets() {
        var card = FSRS.createCard(now: refDate)
        // Graduate to Review
        card = fsrs.schedule(card: card, now: refDate, rating: .easy).card
        // Lapse
        card = fsrs.schedule(card: card, now: card.due, rating: .again).card
        #expect(card.state == .relearning)
        #expect(card.step == 0)

        // Again → still step 0
        card = fsrs.schedule(card: card, now: card.due, rating: .again).card
        #expect(card.step == 0)
        #expect(card.state == .relearning)
    }

    @Test("Good on Relearning with 1 step graduates")
    func goodGraduates() {
        // Default has 1 relearning step [10m]
        var card = FSRS.createCard(now: refDate)
        card = fsrs.schedule(card: card, now: refDate, rating: .easy).card
        card = fsrs.schedule(card: card, now: card.due, rating: .again).card
        #expect(card.state == .relearning)

        // Good → step 1 >= count → graduate
        card = fsrs.schedule(card: card, now: card.due, rating: .good).card
        #expect(card.state == .review)
    }

    @Test("Easy on Relearning graduates immediately")
    func easyGraduates() {
        var card = FSRS.createCard(now: refDate)
        card = fsrs.schedule(card: card, now: refDate, rating: .easy).card
        card = fsrs.schedule(card: card, now: card.due, rating: .again).card
        #expect(card.state == .relearning)

        card = fsrs.schedule(card: card, now: card.due, rating: .easy).card
        #expect(card.state == .review)
    }
}

// MARK: - Integration Tests

@Suite("Integration — Full Lifecycle")
struct LifecycleTests {
    @Test("New → Learning → Review → Relearning → Review")
    func fullCycle() {
        let fsrs = FSRS()
        var card = FSRS.createCard(now: refDate)

        // 1. New → Learning (Good)
        card = fsrs.schedule(card: card, now: refDate, rating: .good).card
        #expect(card.state == .learning)

        // 2. Learning → Review (Good, graduates)
        card = fsrs.schedule(card: card, now: card.due, rating: .good).card
        #expect(card.state == .review)
        let s1 = card.stability
        #expect(s1 > 0)

        // 3. Review → Review (Good, stability grows)
        card = fsrs.schedule(card: card, now: card.due, rating: .good).card
        #expect(card.state == .review)
        #expect(card.stability > s1)

        // 4. Review → Relearning (Again, lapse)
        let sBeforeLapse = card.stability
        card = fsrs.schedule(card: card, now: card.due, rating: .again).card
        #expect(card.state == .relearning)
        #expect(card.lapses == 1)
        #expect(card.stability < sBeforeLapse)

        // 5. Relearning → Review (Good, graduates)
        card = fsrs.schedule(card: card, now: card.due, rating: .good).card
        #expect(card.state == .review)
    }

    @Test("Retrievability returns valid values")
    func retrievability() {
        let fsrs = FSRS()
        var card = FSRS.createCard(now: refDate)

        // New card: retrievability = 0
        #expect(fsrs.retrievability(of: card, now: refDate) == 0)

        // After review
        card = fsrs.schedule(card: card, now: refDate, rating: .good).card
        card = fsrs.schedule(card: card, now: card.due, rating: .good).card

        // At review time: R ≈ 1.0 (just reviewed)
        let rNow = fsrs.retrievability(of: card, now: card.lastReview!)
        expectApprox(rNow, 1.0, tolerance: 0.05)

        // At due date: R ≈ 0.9 (by construction)
        let rDue = fsrs.retrievability(of: card, now: card.due)
        expectApprox(rDue, 0.9, tolerance: 0.05)

        // Well past due: R < 0.9
        let rLate = fsrs.retrievability(of: card, now: card.due.addingTimeInterval(30 * 86400))
        #expect(rLate < 0.9)
    }

    @Test("Long-term scheduler produces valid lifecycle")
    func longTermLifecycle() {
        let fsrs = FSRS(parameters: Parameters(enableShortTerm: false))
        var card = FSRS.createCard(now: refDate)

        // All reviews go directly to Review state
        card = fsrs.schedule(card: card, now: refDate, rating: .good).card
        #expect(card.state == .review)

        card = fsrs.schedule(card: card, now: card.due, rating: .good).card
        #expect(card.state == .review)
        #expect(card.reps == 2)

        // Lapse also stays in Review (no relearning in long-term mode)
        card = fsrs.schedule(card: card, now: card.due, rating: .again).card
        #expect(card.state == .review)
        #expect(card.lapses == 1)
    }
}

@Suite("FSRS — Rollback")
struct RollbackTests {

    // MARK: - Round-trip identity

    @Test("Rollback restores a new card after first review")
    func roundTripFromNew() {
        let fsrs = FSRS()
        let original = FSRS.createCard(now: refDate)
        let result = fsrs.schedule(card: original, now: refDate, rating: .good)

        let rolled = fsrs.rollback(card: result.card, log: result.log)

        #expect(rolled == original)
    }

    @Test("Rollback restores card across all four ratings from new")
    func roundTripAllRatingsFromNew() {
        let fsrs = FSRS()
        let original = FSRS.createCard(now: refDate)
        let preview = fsrs.schedule(card: original, now: refDate)

        for item in [preview.again, preview.hard, preview.good, preview.easy] {
            let rolled = fsrs.rollback(card: item.card, log: item.log)
            #expect(rolled == original, "\(item.log.rating) round-trip failed")
        }
    }

    @Test("Rollback restores a learning card after a step")
    func roundTripFromLearning() {
        let fsrs = FSRS()
        let new = FSRS.createCard(now: refDate)
        // First Good moves new -> learning step 1.
        let afterFirst = fsrs.schedule(card: new, now: refDate, rating: .good).card
        #expect(afterFirst.state == .learning)

        let later = afterFirst.due
        let result = fsrs.schedule(card: afterFirst, now: later, rating: .good)
        let rolled = fsrs.rollback(card: result.card, log: result.log)

        #expect(rolled == afterFirst)
    }

    @Test("Rollback restores a Review-state card after Good")
    func roundTripFromReviewGood() {
        let fsrs = FSRS()
        // Drive the card all the way to Review state.
        var card = FSRS.createCard(now: refDate)
        card = fsrs.schedule(card: card, now: refDate, rating: .easy).card  // graduates to Review
        #expect(card.state == .review)
        let snapshot = card

        let result = fsrs.schedule(card: card, now: card.due, rating: .good)
        let rolled = fsrs.rollback(card: result.card, log: result.log)

        #expect(rolled == snapshot)
    }

    // MARK: - Lapse decrement

    @Test("Rollback decrements lapses when log.state == .review and rating == .again")
    func decrementsLapsesOnReviewAgain() {
        let fsrs = FSRS()
        var card = FSRS.createCard(now: refDate)
        card = fsrs.schedule(card: card, now: refDate, rating: .easy).card  // -> Review
        #expect(card.state == .review)
        let lapsesBefore = card.lapses

        let result = fsrs.schedule(card: card, now: card.due, rating: .again)
        #expect(result.card.lapses == lapsesBefore + 1)

        let rolled = fsrs.rollback(card: result.card, log: result.log)
        #expect(rolled.lapses == lapsesBefore)
        #expect(rolled == card)
    }

    @Test("Rollback does not decrement lapses on Good rating")
    func noDecrementOnGood() {
        let fsrs = FSRS()
        var card = FSRS.createCard(now: refDate)
        card = fsrs.schedule(card: card, now: refDate, rating: .easy).card
        let lapsesBefore = card.lapses

        let result = fsrs.schedule(card: card, now: card.due, rating: .good)
        let rolled = fsrs.rollback(card: result.card, log: result.log)
        #expect(rolled.lapses == lapsesBefore)
    }

    // MARK: - Reps decrement / clamping

    @Test("Rollback decrements reps but clamps at zero")
    func repsClampedAtZero() {
        let fsrs = FSRS()
        let card = FSRS.createCard(now: refDate)
        let result = fsrs.schedule(card: card, now: refDate, rating: .good)
        let rolled = fsrs.rollback(card: result.card, log: result.log)

        #expect(rolled.reps == 0)  // original was 0, now-1 clamped back to 0
    }

    // MARK: - Multiple-step rollback chain

    @Test("Sequential rollback peels reviews in reverse order")
    func sequentialRollback() {
        let fsrs = FSRS()
        var card = FSRS.createCard(now: refDate)

        let r1 = fsrs.schedule(card: card, now: refDate, rating: .good)
        let snapshot1 = card
        card = r1.card

        let r2 = fsrs.schedule(card: card, now: card.due, rating: .good)
        let snapshot2 = card
        card = r2.card

        // Roll back the second review.
        let rolledOnce = fsrs.rollback(card: card, log: r2.log)
        #expect(rolledOnce == snapshot2)

        // Roll back the first review.
        let rolledTwice = fsrs.rollback(card: rolledOnce, log: r1.log)
        #expect(rolledTwice == snapshot1)
    }

    // MARK: - Long-term mode

    @Test("Rollback works in long-term mode for review-state cards")
    func longTermReviewRollback() {
        var params = Parameters()
        params.enableShortTerm = false
        let fsrs = FSRS(parameters: params)
        var card = FSRS.createCard(now: refDate)
        card = fsrs.schedule(card: card, now: refDate, rating: .good).card  // long-term: -> Review
        #expect(card.state == .review)
        let snapshot = card

        let result = fsrs.schedule(card: card, now: card.due, rating: .again)
        #expect(result.card.lapses == snapshot.lapses + 1)

        let rolled = fsrs.rollback(card: result.card, log: result.log)
        #expect(rolled == snapshot)
    }
}

@Suite("Integration — Review Log")
struct ReviewLogTests {
    @Test("Log captures pre-review state")
    func capturesPreState() {
        let fsrs = FSRS()
        let card = FSRS.createCard(now: refDate)
        let result = fsrs.schedule(card: card, now: refDate, rating: .good)

        #expect(result.log.state == .new)
        #expect(result.log.rating == .good)
        #expect(result.log.stability == 0)
        #expect(result.log.difficulty == 0)
    }

    @Test("Log records correct rating")
    func recordsRating() {
        let fsrs = FSRS()
        let card = FSRS.createCard(now: refDate)
        let result = fsrs.schedule(card: card, now: refDate)

        #expect(result.again.log.rating == .again)
        #expect(result.hard.log.rating == .hard)
        #expect(result.good.log.rating == .good)
        #expect(result.easy.log.rating == .easy)
    }
}

// MARK: - Fuzz Tests

@Suite("IntervalFuzzer")
struct FuzzTests {
    @Test("Short intervals not fuzzed")
    func shortNotFuzzed() {
        #expect(IntervalFuzzer.fuzz(interval: 1, elapsedDays: 0, maximumInterval: 365, seed: "x") == 1)
        #expect(IntervalFuzzer.fuzz(interval: 2, elapsedDays: 0, maximumInterval: 365, seed: "x") == 2)
    }

    @Test("Fuzzed interval within reasonable range")
    func withinRange() {
        for i in 0..<100 {
            let fuzzed = IntervalFuzzer.fuzz(interval: 10, elapsedDays: 5, maximumInterval: 365, seed: "s\(i)")
            #expect(fuzzed >= 6, "Fuzzed interval too low: \(fuzzed)")
            #expect(fuzzed <= 14, "Fuzzed interval too high: \(fuzzed)")
        }
    }

    @Test("Fuzz respects maximum interval")
    func respectsMax() {
        for i in 0..<50 {
            let fuzzed = IntervalFuzzer.fuzz(interval: 100, elapsedDays: 50, maximumInterval: 100, seed: "s\(i)")
            #expect(fuzzed <= 100)
        }
    }
}

// MARK: - Edge Case Tests

@Suite("Edge Cases")
struct EdgeCaseTests {
    @Test("Weights clamped to valid ranges")
    func weightsClamped() {
        var weights = Weights(array: Array(repeating: -100.0, count: 21))
        // w[0]..w[3] clamped to [0.001, 100]
        #expect(weights[0] >= 0.001)
        // w[4] clamped to [1, 10]
        #expect(weights[4] >= 1.0)
        // w[20] clamped to [0.1, 0.8]
        #expect(weights[20] >= 0.1)

        weights = Weights(array: Array(repeating: 1000.0, count: 21))
        #expect(weights[0] <= 100.0)
        #expect(weights[4] <= 10.0)
        #expect(weights[20] <= 0.8)
    }

    @Test("Parameters retention clamped")
    func retentionClamped() {
        let low = Parameters(requestRetention: 0.0)
        #expect(low.requestRetention >= 0.01)

        let high = Parameters(requestRetention: 1.0)
        #expect(high.requestRetention <= 0.99)
    }

    @Test("Card with empty learning steps graduates immediately")
    func emptySteps() {
        let fsrs = FSRS(parameters: Parameters(learningSteps: []))
        let card = FSRS.createCard(now: refDate)
        let result = fsrs.schedule(card: card, now: refDate, rating: .good)
        #expect(result.card.state == .review)
    }

    @Test("Card with empty relearning steps stays in Review on lapse")
    func emptyRelearningSteps() {
        let fsrs = FSRS(parameters: Parameters(relearningSteps: []))
        var card = FSRS.createCard(now: refDate)
        card = fsrs.schedule(card: card, now: refDate, rating: .easy).card
        #expect(card.state == .review)

        // Lapse with no relearning steps → stays in Review
        card = fsrs.schedule(card: card, now: card.due, rating: .again).card
        #expect(card.state == .review)
        #expect(card.lapses == 1)
    }
}

// MARK: - Model Tests

@Suite("Models")
struct ModelTests {
    @Test("Rating is ordered")
    func ratingOrdered() {
        #expect(Rating.again < Rating.hard)
        #expect(Rating.hard < Rating.good)
        #expect(Rating.good < Rating.easy)
    }

    @Test("Card default state is new")
    func defaultCard() {
        let card = Card()
        #expect(card.state == .new)
        #expect(card.stability == 0)
        #expect(card.difficulty == 0)
        #expect(card.reps == 0)
        #expect(card.lapses == 0)
        #expect(card.lastReview == nil)
    }

    @Test("Card Codable round-trip")
    func cardCodable() throws {
        var card = Card(due: refDate)
        card.stability = 5.0
        card.difficulty = 3.0
        card.state = .review

        let data = try JSONEncoder().encode(card)
        let decoded = try JSONDecoder().decode(Card.self, from: data)
        #expect(decoded == card)
    }

    @Test("SchedulingResult Codable round-trip")
    func schedulingResultCodable() throws {
        // Run the card through two reviews so stability/difficulty/reps are
        // non-zero and lastReview is populated on every rating branch.
        let fsrs = FSRS()
        var card = FSRS.createCard(now: refDate)
        card = fsrs.schedule(card: card, now: refDate, rating: .good).card
        card = fsrs.schedule(card: card, now: card.due, rating: .good).card

        let result = fsrs.schedule(card: card, now: card.due)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(result)
        let decoded = try decoder.decode(SchedulingResult.self, from: data)
        #expect(decoded == result)
    }

    @Test("Weights default has 21 values")
    func weightsCount() {
        #expect(Weights.default.values.count == 21)
    }

    @Test("Weights subscript access")
    func weightsSubscript() {
        let w = Weights.default
        #expect(w[0] == w.values[0])
        #expect(w[20] == w.values[20])
    }
}

// MARK: - ts-fsrs parity (locked numerical reference values)

/// Pins Swift's output to the Python/TS reference implementation.
///
/// Divergences here mean a bug — these constants come from running the same
/// review sequence through the canonical ts-fsrs (`packages/fsrs`). Each
/// value is rounded to 8 decimals as ts-fsrs does (`roundTo(x, 8)`).
@Suite("ts-fsrs parity")
struct TSFSRSParityTests {

    /// Default `w[0]` must equal ts-fsrs `default_w[0]` (constant.ts:25).
    @Test("default_w[0] = 0.212")
    func defaultW0() {
        #expect(Weights.default[0] == 0.212)
    }

    /// Stability at step 1 equals `init_stability(Again) = max(w[0], 0.1)`.
    /// `initialStability` is a straight `max(w[g-1], 0.1)` in both Swift and
    /// ts-fsrs (no rounding), so exact equality is the correct assertion.
    @Test("initialStability(.again) = 0.212")
    func initialStabilityAgain() {
        let algo = FSRSAlgorithm(parameters: Parameters())
        #expect(algo.initialStability(rating: .again) == 0.212)
    }

    /// Mean-reversion target in `nextDifficulty` must use the raw (unclamped
    /// but 8-decimal rounded) `init_difficulty(Easy)`. With default w[4]=6.4133,
    /// w[5]=0.8334 this is `6.4133 - exp(3 * 0.8334) + 1 ≈ -4.77163070`.
    /// ts-fsrs algorithm.ts:222-230.
    ///
    /// After applying `roundTo(..., 8)` at every ts-fsrs site (decay factor,
    /// interval modifier, init_difficulty, linear_damping, mean_reversion,
    /// each stability formula, and the lapse-floor clamp), Swift produces
    /// byte-identical output for the reference sequences below.
    @Test("Sequence A step 1 — New + Good at t=0 → S=2.3065, D=2.11810397")
    func sequenceA_step1() {
        let fsrs = FSRS(parameters: Parameters(enableShortTerm: false))
        let card = FSRS.createCard(now: refDate)
        let after1 = fsrs.schedule(card: card, now: refDate, rating: .good).card
        #expect(after1.stability == 2.3065)
        #expect(after1.difficulty == 2.11810397)
    }

    /// The key regression test for bug #2: before the fix, Swift produced
    /// D=2.11698587 because `nextDifficulty` multiplied the *clamped*
    /// `init_difficulty(Easy) = 1.0` by `w[7]` instead of the raw ≈ -4.77.
    ///
    /// Also the byte-parity canary: after applying `roundTo(..., 8)` at
    /// every ts-fsrs site, these values should match ts-fsrs to all 8
    /// printed decimals exactly.
    @Test("Sequence A step 2 — +Good at t=2 days → S=10.96433194, D=2.11121424")
    func sequenceA_step2() {
        let fsrs = FSRS(parameters: Parameters(enableShortTerm: false))
        var card = FSRS.createCard(now: refDate)
        card = fsrs.schedule(card: card, now: refDate, rating: .good).card
        // Advance exactly 2 UTC days. refDate is at a known instant; add 2*86400.
        let t2 = refDate.addingTimeInterval(2 * 86_400)
        card = fsrs.schedule(card: card, now: t2, rating: .good).card
        #expect(card.stability == 10.96433194)
        #expect(card.difficulty == 2.11121424)
    }

    @Test("Sequence A step 3 — +Good at t=11 days → S=46.28021494, D=2.10433140")
    func sequenceA_step3() {
        let fsrs = FSRS(parameters: Parameters(enableShortTerm: false))
        var card = FSRS.createCard(now: refDate)
        card = fsrs.schedule(card: card, now: refDate, rating: .good).card
        let t2 = refDate.addingTimeInterval(2 * 86_400)
        card = fsrs.schedule(card: card, now: t2, rating: .good).card
        // 11 UTC days after step 2.
        let t3 = t2.addingTimeInterval(11 * 86_400)
        card = fsrs.schedule(card: card, now: t3, rating: .good).card
        #expect(card.stability == 46.28021494)
        #expect(card.difficulty == 2.10433140)
    }

    /// `Card.elapsedDays` must match ts-fsrs `dateDiffInDays` semantics:
    /// UTC calendar-day boundaries crossed, not elapsed seconds.
    @Test("Card.elapsedDays uses UTC calendar-day semantics")
    func elapsedDaysUTC() {
        // 2026-01-15 23:00:00 UTC → timestamp
        let dayA = Date(timeIntervalSince1970: 1_768_604_400)
        // 2026-01-16 01:00:00 UTC: only 2 hours later, but 1 UTC boundary crossed.
        let dayB = dayA.addingTimeInterval(2 * 3600)
        // 2026-01-16 22:00:00 UTC: 23 hours after A, still only 1 boundary.
        let dayBLate = dayA.addingTimeInterval(23 * 3600)
        // 2026-01-15 00:30:00 UTC (same UTC day as A): 0 boundaries.
        let dayASameDay = dayA.addingTimeInterval(-22.5 * 3600)

        var card = Card()
        card.lastReview = dayA
        #expect(card.elapsedDays(now: dayB) == 1)
        #expect(card.elapsedDays(now: dayBLate) == 1)
        #expect(card.elapsedDays(now: dayASameDay) == 0)
        // Going backwards clamps to 0.
        #expect(card.elapsedDays(now: dayA.addingTimeInterval(-86_400)) == 0)
    }

    /// Same-day dispatch: `t == 0` (strict), not `Int(t) == 0`.
    /// Regression: previously 11 hours of elapsed time was truncated to
    /// `Int(11/24) == 0` and wrongly triggered the short-term formula.
    @Test("Same-day check uses strict t == 0, not Int-truncation")
    func sameDayStrict() {
        let algo = FSRSAlgorithm(parameters: Parameters(enableShortTerm: true))
        let s = 5.0, d = 5.0
        // t == 0 → short-term formula
        let (s0, _) = algo.nextState(stability: s, difficulty: d, elapsedDays: 0, rating: .good)
        expectApprox(s0, algo.nextShortTermStability(s: s, rating: .good))
        // t == 1 → recall formula (not short-term)
        let r1 = algo.forgettingCurve(elapsedDays: 1.0, stability: s)
        let (s1, _) = algo.nextState(stability: s, difficulty: d, elapsedDays: 1, rating: .good)
        expectApprox(s1, algo.nextRecallStability(d: d, s: s, r: r1, rating: .good))
    }

    // MARK: - Scheduler semantics

    /// Hard on a new card uses `round((firstStep + secondStep) / 2)` minutes,
    /// not `steps[0]`. Default `[1m, 10m]` → 6 minutes.
    /// See ts-fsrs `getHardInterval` (strategies/learning_steps.ts:50-56).
    @Test("BasicScheduler: Hard on new card uses avg of first two steps (6m)")
    func hardNewCardDefaultSteps() {
        let fsrs = FSRS()
        let card = FSRS.createCard(now: refDate)
        let result = fsrs.schedule(card: card, now: refDate, rating: .hard)
        let expected = refDate.addingTimeInterval(360)
        expectApprox(result.card.due.timeIntervalSinceReferenceDate,
                     expected.timeIntervalSinceReferenceDate, tolerance: 1.0)
    }

    /// Single-step configs fall through the `steps_length === 1` branch:
    /// `round(firstStep * 1.5)`. `round(5 * 1.5) = round(7.5) = 8` in JS
    /// (half rounds away from zero for positives).
    @Test("BasicScheduler: Hard on new card with single 5m step schedules 8m")
    func hardNewCardSingleStep() {
        let params = Parameters(learningSteps: [300])  // 5 minutes
        let fsrs = FSRS(parameters: params)
        let card = FSRS.createCard(now: refDate)
        let result = fsrs.schedule(card: card, now: refDate, rating: .hard)
        let expected = refDate.addingTimeInterval(480)
        expectApprox(result.card.due.timeIntervalSinceReferenceDate,
                     expected.timeIntervalSinceReferenceDate, tolerance: 1.0)
    }

    /// Once a card reaches step 1 of the default `[1m, 10m]` config, Hard
    /// keeps it at step 1 but still schedules the step-independent 6-minute
    /// duration — not `steps[1] = 10m`. Pre-fix Swift scheduled +600s.
    @Test("BasicScheduler: Hard on learning step 1 uses avg (not steps[1])")
    func hardLearningStep1() {
        let fsrs = FSRS()
        var card = FSRS.createCard(now: refDate)
        card = fsrs.schedule(card: card, now: refDate, rating: .good).card
        #expect(card.step == 1)
        let reviewAt = card.due
        card = fsrs.schedule(card: card, now: reviewAt, rating: .hard).card
        let expected = reviewAt.addingTimeInterval(360)
        expectApprox(card.due.timeIntervalSinceReferenceDate,
                     expected.timeIntervalSinceReferenceDate, tolerance: 1.0)
    }

    /// ts-fsrs `LongTermScheduler.next_interval` enforces `again + 1 <= hard`,
    /// not `again <= hard`. See long_term_scheduler.ts:112-115.
    @Test("LongTermScheduler: again < hard strictly")
    func longTermAgainStrictlyLessThanHard() {
        let fsrs = FSRS(parameters: Parameters(enableShortTerm: false))
        let card = FSRS.createCard(now: refDate)
        let result = fsrs.schedule(card: card, now: refDate)
        #expect(result.again.card.scheduledDays < result.hard.card.scheduledDays)
    }

    /// When a learning step duration is ≥ 1 day, the card moves to Review
    /// but `due` uses the raw step duration — *not* the FSRS interval.
    /// See ts-fsrs basic_scheduler.ts:89-98.
    @Test("BasicScheduler: learning step ≥ 1 day uses minute-based due")
    func longStepGraduation() {
        // [1 minute, 2 days] — after Good from new, card moves to step 1
        // which is 2 days long. ts-fsrs routes that through the `>= 1440`
        // branch: state becomes Review, due = now + 2 days, learning_steps
        // is preserved at the target index.
        let params = Parameters(learningSteps: [60, 86400 * 2])
        let fsrs = FSRS(parameters: params)
        let card = FSRS.createCard(now: refDate)
        let result = fsrs.schedule(card: card, now: refDate, rating: .good)
        #expect(result.card.state == .review)
        let expected = refDate.addingTimeInterval(86400 * 2)
        expectApprox(result.card.due.timeIntervalSinceReferenceDate,
                     expected.timeIntervalSinceReferenceDate, tolerance: 1.0)
    }
}

// MARK: - roundTo helper (ts-fsrs `help.ts` roundTo parity)

/// Byte-for-byte parity with ts-fsrs requires mirroring its rounding behaviour
/// exactly. These tests pin `FSRSAlgorithm.roundTo` to known reference values
/// so a future change to the rounding mode (e.g. accidental banker's rounding)
/// is caught immediately.
@Suite("roundTo — ts-fsrs help.ts parity")
struct RoundToTests {

    /// JS `Math.round(1.234567895 * 1e8) / 1e8` yields `1.23456790` because
    /// halves round away from zero for positive numbers. `.toNearestOrAwayFromZero`
    /// matches that within our non-negative FSRS domain.
    @Test("roundTo(1.234567895, 8) == 1.23456790 — half rounds up for positives")
    func halfRoundsAwayFromZero() {
        #expect(FSRSAlgorithm.roundTo(1.234567895, decimals: 8) == 1.23456790)
    }

    /// Classic floating-point noise: `0.1 + 0.2 == 0.30000000000000004` in IEEE-754.
    /// Rounding to 8 decimals collapses that to the exact `0.3`.
    @Test("roundTo(0.1 + 0.2, 8) == 0.3 — collapses IEEE-754 noise")
    func collapsesFPNoise() {
        #expect(FSRSAlgorithm.roundTo(0.1 + 0.2, decimals: 8) == 0.3)
    }

    /// Exact values survive rounding unchanged.
    @Test("roundTo is idempotent on already-rounded values")
    func idempotent() {
        #expect(FSRSAlgorithm.roundTo(2.3065, decimals: 8) == 2.3065)
        #expect(FSRSAlgorithm.roundTo(0.212, decimals: 8) == 0.212)
    }

    /// Values below the precision floor round to zero.
    @Test("roundTo(1e-9, 8) == 0 — below precision floor")
    func belowPrecisionFloor() {
        #expect(FSRSAlgorithm.roundTo(1e-9, decimals: 8) == 0.0)
    }
}

// MARK: - scheduledDays stored-field tests

/// `scheduledDays` is a stored field on `Card`, set by the scheduler at review
/// time and 0 for new / in-day (re)learning cards. Mirrors ts-fsrs
/// `scheduled_days` in models.ts:50-64.
@Suite("Card.scheduledDays")
struct ScheduledDaysTests {

    /// A freshly created card has never been scheduled.
    @Test("New card has scheduledDays == 0")
    func newCardZero() {
        let card = FSRS.createCard(now: refDate)
        #expect(card.scheduledDays == 0)
    }

    /// Basic scheduler with default steps [1m, 10m]: Good on a new card moves
    /// the card into Learning at step 1 (10 minutes), which is < 1 day. ts-fsrs
    /// basic_scheduler.ts:82 sets `scheduled_days = 0` for this branch.
    @Test("Basic: Good on new card (in-day learning step) sets scheduledDays == 0")
    func basicGoodNewCardZero() {
        let fsrs = FSRS()
        let card = FSRS.createCard(now: refDate)
        let result = fsrs.schedule(card: card, now: refDate, rating: .good)
        #expect(result.card.state == .learning)
        #expect(result.card.scheduledDays == 0)
    }

    /// Basic scheduler, Good on a Review-state card: scheduled_days equals the
    /// integer interval returned by `algorithm.nextInterval(stability:)` after
    /// ordering (Good is only ever pushed above Hard, never clamped down).
    @Test("Basic: Good in Review state sets scheduledDays to nextInterval(s)")
    func basicGoodReviewMatchesInterval() {
        // Disable fuzz so we get exact-match interval values.
        let params = Parameters(enableFuzz: false)
        let fsrs = FSRS(parameters: params)
        let algo = FSRSAlgorithm(parameters: params)

        // Bring a card into Review with non-trivial stability.
        var card = FSRS.createCard(now: refDate)
        card = fsrs.schedule(card: card, now: refDate, rating: .good).card
        card = fsrs.schedule(card: card, now: card.due, rating: .good).card
        #expect(card.state == .review)

        let result = fsrs.schedule(card: card, now: card.due, rating: .good)
        // Re-derive: the basic scheduler's Good interval is ordered via
        // `max(goodI, hardI + 1)`. For Good on a Review card with growing
        // stability the raw value dominates, so equality against the raw
        // algorithm value is correct.
        let expected = algo.nextInterval(stability: result.card.stability)
        #expect(result.card.scheduledDays == expected)
    }

    /// Long-term scheduler: every rating routes to Review and sets
    /// `scheduled_days` = the ordered interval. long_term_scheduler.ts:117-127.
    @Test("LongTerm: scheduledDays matches due-date interval for all ratings")
    func longTermAllRatings() {
        let fsrs = FSRS(parameters: Parameters(enableFuzz: false,
                                               enableShortTerm: false))
        // Warm up to a Review-state card with non-trivial stability.
        var card = FSRS.createCard(now: refDate)
        card = fsrs.schedule(card: card, now: refDate, rating: .good).card
        card = fsrs.schedule(card: card, now: card.due, rating: .good).card
        #expect(card.state == .review)

        let result = fsrs.schedule(card: card, now: card.due)
        for rating in Rating.allCases {
            let item = result[rating]
            // `scheduledDays` must match the day-delta between `lastReview`
            // and `due` — that's the same integer the scheduler plugged in.
            let deltaSeconds = item.card.due.timeIntervalSince(item.card.lastReview!)
            let expected = Int((deltaSeconds / 86_400.0).rounded())
            let label = "\(rating)"
            #expect(item.card.scheduledDays == expected,
                    "\(label): scheduledDays=\(item.card.scheduledDays) expected=\(expected)")
            #expect(item.card.scheduledDays >= 1)
        }
        // Ordering: again < hard < good < easy
        #expect(result.again.card.scheduledDays < result.hard.card.scheduledDays)
        #expect(result.hard.card.scheduledDays < result.good.card.scheduledDays)
        #expect(result.good.card.scheduledDays < result.easy.card.scheduledDays)
    }

    /// Old persisted Card JSON (before `scheduledDays` was a stored field)
    /// must still decode. Legacy formula: `Int((due - lastReview) / 86400)`,
    /// which is 0 when `lastReview` is absent.
    @Test("Codable backward compat: missing scheduledDays decodes to legacy value")
    func codableBackwardCompat() throws {
        // Hand-written legacy JSON: no `scheduledDays` field, no `lastReview`.
        // `CardState` is an Int-raw enum (`new = 0`), and Swift's default
        // Date strategy is `timeIntervalSinceReferenceDate`.
        let legacyJSON = """
        {
            "due": 800000000,
            "stability": 0,
            "difficulty": 0,
            "state": 0,
            "step": 0,
            "reps": 0,
            "lapses": 0,
            "lastReview": null
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Card.self, from: legacyJSON)
        #expect(decoded.scheduledDays == 0)
        #expect(decoded.state == .new)
    }

    /// Legacy JSON with a non-nil `lastReview` and a `due` 5 days later should
    /// reconstruct `scheduledDays = 5` via the fallback formula.
    @Test("Codable backward compat: reconstructs scheduledDays from due - lastReview")
    func codableBackwardCompatReconstructs() throws {
        // due = 800_000_000 + 5*86400 = 800_432_000
        // lastReview = 800_000_000
        // state = 2 (review)
        let legacyJSON = """
        {
            "due": 800432000,
            "stability": 5,
            "difficulty": 5,
            "state": 2,
            "step": 0,
            "reps": 3,
            "lapses": 0,
            "lastReview": 800000000
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(Card.self, from: legacyJSON)
        #expect(decoded.scheduledDays == 5)
    }

    /// Modern Card with non-zero `scheduledDays` must round-trip through
    /// encode/decode unchanged.
    @Test("Codable forward round-trip preserves scheduledDays")
    func codableForwardRoundTrip() throws {
        let fsrs = FSRS(parameters: Parameters(enableFuzz: false,
                                               enableShortTerm: false))
        var card = FSRS.createCard(now: refDate)
        card = fsrs.schedule(card: card, now: refDate, rating: .good).card
        card = fsrs.schedule(card: card, now: card.due, rating: .good).card
        #expect(card.scheduledDays > 0)

        let data = try JSONEncoder().encode(card)
        let decoded = try JSONDecoder().decode(Card.self, from: data)
        #expect(decoded.scheduledDays == card.scheduledDays)
        #expect(decoded == card)
    }
}
