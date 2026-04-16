import Foundation

/// Scheduler that uses learning steps for new and re-learning cards.
///
/// New cards progress through ``Parameters/learningSteps`` before
/// graduating to the `review` state. Lapsed cards (Again on a Review card)
/// enter `relearning` and progress through ``Parameters/relearningSteps``.
///
/// Step progression per rating:
/// - **Again**: reset to step 0
/// - **Hard**: repeat current step
/// - **Good**: advance to next step (graduate if exhausted)
/// - **Easy**: graduate immediately to Review
///
/// For new cards (no "current step"), Again and Hard both start at step 0,
/// and Good starts at step 1.
struct BasicScheduler: Sendable {

    let algorithm: FSRSAlgorithm
    let parameters: Parameters

    func schedule(card: Card, now: Date) -> SchedulingResult {
        switch card.state {
        case .new:       return scheduleNew(card: card, now: now)
        case .learning:  return scheduleLearning(card: card, now: now)
        case .review:    return scheduleReview(card: card, now: now)
        case .relearning: return scheduleRelearning(card: card, now: now)
        }
    }

    // MARK: - New Card

    private func scheduleNew(card: Card, now: Date) -> SchedulingResult {
        let t = card.elapsedDays(now: now)
        let steps = parameters.learningSteps

        func outcome(_ rating: Rating) -> RecordLogItem {
            let (newS, newD) = algorithm.nextState(
                stability: card.stability,
                difficulty: card.difficulty,
                elapsedDays: t,
                rating: rating
            )

            var newCard = card
            newCard.stability = newS
            newCard.difficulty = newD
            newCard.reps += 1
            newCard.lastReview = now

            // Step target for a new card: Again→0, Hard→0, Good→1, Easy→graduate
            switch rating {
            case .again:
                applyStep(0, steps: steps, to: &newCard, now: now,
                          learningState: .learning)
            case .hard:
                applyHard(currentStep: 0, steps: steps, stability: newS,
                          to: &newCard, now: now, learningState: .learning)
            case .good:
                applyStep(1, steps: steps, to: &newCard, now: now,
                          learningState: .learning)
            case .easy:
                graduate(&newCard, stability: newS, now: now)
            }

            return RecordLogItem(
                card: newCard,
                log: makeLog(rating: rating, card: card, elapsedDays: t, now: now)
            )
        }

        return buildResult(outcome)
    }

    // MARK: - Learning Card

    private func scheduleLearning(card: Card, now: Date) -> SchedulingResult {
        let t = card.elapsedDays(now: now)
        let steps = parameters.learningSteps

        func outcome(_ rating: Rating) -> RecordLogItem {
            let (newS, newD) = algorithm.nextState(
                stability: card.stability,
                difficulty: card.difficulty,
                elapsedDays: t,
                rating: rating
            )

            var newCard = card
            newCard.stability = newS
            newCard.difficulty = newD
            newCard.reps += 1
            newCard.lastReview = now

            switch rating {
            case .again:
                applyStep(0, steps: steps, to: &newCard, now: now,
                          learningState: .learning)
            case .hard:
                applyHard(currentStep: card.step, steps: steps, stability: newS,
                          to: &newCard, now: now, learningState: .learning)
            case .good:
                applyStep(card.step + 1, steps: steps, to: &newCard, now: now,
                          learningState: .learning)
            case .easy:
                graduate(&newCard, stability: newS, now: now)
            }

            return RecordLogItem(
                card: newCard,
                log: makeLog(rating: rating, card: card, elapsedDays: t, now: now)
            )
        }

        return buildResult(outcome)
    }

    // MARK: - Review Card

    private func scheduleReview(card: Card, now: Date) -> SchedulingResult {
        let t = card.elapsedDays(now: now)
        let relearningSteps = parameters.relearningSteps

        // Compute FSRS state for all 4 ratings
        var fsrsStates: [Rating: (s: Double, d: Double)] = [:]
        for rating in Rating.allCases {
            let (newS, newD) = algorithm.nextState(
                stability: card.stability,
                difficulty: card.difficulty,
                elapsedDays: t,
                rating: rating
            )
            fsrsStates[rating] = (newS, newD)
        }

        // Compute and order intervals for Hard/Good/Easy. ts-fsrs caps Hard
        // at Good *first*, then bumps Good above Hard — reversing the order
        // would let Hard climb arbitrarily high. See basic_scheduler.ts:220-227.
        var hardI = algorithm.nextInterval(stability: fsrsStates[.hard]!.s)
        var goodI = algorithm.nextInterval(stability: fsrsStates[.good]!.s)
        hardI = min(hardI, goodI)
        goodI = max(goodI, hardI + 1)
        let easyI = max(algorithm.nextInterval(stability: fsrsStates[.easy]!.s), goodI + 1)

        var intervals: [Rating: Int] = [.hard: hardI, .good: goodI, .easy: easyI]

        // Apply fuzz if enabled
        if parameters.enableFuzz {
            // Seed mirrors ts-fsrs `DefaultInitSeedStrategy` (seed.ts):
            // `${review_time_ms}_${reps}_${D*S}`. Swift's Double formatting
            // differs slightly from JS `Number.toString()` (e.g. "5.0" vs "5"),
            // so our seed strings are NOT byte-identical to ts-fsrs — we only
            // guarantee Swift-internal determinism (same inputs → same output).
            let seed = fuzzSeed(card: card, now: now)
            for rating: Rating in [.hard, .good, .easy] {
                intervals[rating] = IntervalFuzzer.fuzz(
                    interval: intervals[rating]!,
                    elapsedDays: t,
                    maximumInterval: parameters.maximumInterval,
                    seed: seed
                )
            }
        }

        func outcome(_ rating: Rating) -> RecordLogItem {
            let (newS, newD) = fsrsStates[rating]!

            var newCard = card
            newCard.stability = newS
            newCard.difficulty = newD
            newCard.reps += 1
            newCard.lastReview = now

            if rating == .again {
                newCard.lapses += 1
                if relearningSteps.isEmpty {
                    // No relearning steps — go directly back to Review
                    let againI = algorithm.nextInterval(stability: newS)
                    newCard.state = .review
                    newCard.step = 0
                    newCard.scheduledDays = againI
                    newCard.due = now.addingTimeInterval(Double(againI) * 86400.0)
                } else {
                    newCard.state = .relearning
                    newCard.step = 0
                    // In-day relearning step — not on a day-based schedule yet.
                    newCard.scheduledDays = 0
                    newCard.due = now.addingTimeInterval(relearningSteps[0])
                }
            } else {
                let interval = intervals[rating]!
                newCard.state = .review
                newCard.step = 0
                newCard.scheduledDays = interval
                newCard.due = now.addingTimeInterval(Double(interval) * 86400.0)
            }

            return RecordLogItem(
                card: newCard,
                log: makeLog(rating: rating, card: card, elapsedDays: t, now: now)
            )
        }

        return buildResult(outcome)
    }

    // MARK: - Relearning Card

    private func scheduleRelearning(card: Card, now: Date) -> SchedulingResult {
        let t = card.elapsedDays(now: now)
        let steps = parameters.relearningSteps

        func outcome(_ rating: Rating) -> RecordLogItem {
            let (newS, newD) = algorithm.nextState(
                stability: card.stability,
                difficulty: card.difficulty,
                elapsedDays: t,
                rating: rating
            )

            var newCard = card
            newCard.stability = newS
            newCard.difficulty = newD
            newCard.reps += 1
            newCard.lastReview = now

            switch rating {
            case .again:
                applyStep(0, steps: steps, to: &newCard, now: now,
                          learningState: .relearning)
            case .hard:
                applyHard(currentStep: card.step, steps: steps, stability: newS,
                          to: &newCard, now: now, learningState: .relearning)
            case .good:
                applyStep(card.step + 1, steps: steps, to: &newCard, now: now,
                          learningState: .relearning)
            case .easy:
                graduate(&newCard, stability: newS, now: now)
            }

            return RecordLogItem(
                card: newCard,
                log: makeLog(rating: rating, card: card, elapsedDays: t, now: now)
            )
        }

        return buildResult(outcome)
    }

    // MARK: - Helpers

    /// Apply a learning step, or graduate if steps are exhausted.
    ///
    /// Handles three branches, mirroring ts-fsrs `applyLearningSteps`
    /// (basic_scheduler.ts:65-109):
    /// 1. `targetStep` is exhausted → graduate with the FSRS interval.
    /// 2. Step duration is ≥ 1 day → state becomes Review, but the `due`
    ///    date uses the raw step duration (not the FSRS interval) and
    ///    `step` is preserved.
    /// 3. Step duration is < 1 day → normal Learning/Relearning schedule.
    private func applyStep(
        _ targetStep: Int,
        steps: [TimeInterval],
        to card: inout Card,
        now: Date,
        learningState: CardState
    ) {
        if steps.isEmpty || targetStep >= steps.count {
            // Steps exhausted — graduate to Review using the FSRS interval.
            graduate(&card, stability: card.stability, now: now)
            return
        }

        applyCustomDuration(steps[targetStep],
                            targetStep: targetStep, to: &card, now: now,
                            learningState: learningState)
    }

    /// Apply a scheduled duration to a card without consulting `steps[]`.
    ///
    /// Used by Hard (which uses the step-independent `getHardInterval`
    /// duration) and as the core of ``applyStep(_:steps:to:now:learningState:)``.
    ///
    /// When `duration` ≥ 1 day, ts-fsrs moves the card to Review but still
    /// uses the minute-based due date (not an FSRS interval). See
    /// basic_scheduler.ts:89-98.
    private func applyCustomDuration(
        _ duration: TimeInterval,
        targetStep: Int,
        to card: inout Card,
        now: Date,
        learningState: CardState
    ) {
        if duration >= 86400 {
            // Duration ≥ 1 day — move to Review with the raw duration. The
            // step index is preserved (matches `nextCard.learning_steps =
            // next_steps` in ts-fsrs). ts-fsrs basic_scheduler.ts:98 sets
            // `scheduled_days = Math.floor(scheduled_minutes / 1440)`, which
            // is the same as flooring the second-based duration to whole days.
            card.state = .review
            card.step = targetStep
            card.scheduledDays = Int((duration / 86_400.0).rounded(.down))
            card.due = now.addingTimeInterval(duration)
        } else {
            // In-day (re)learning step — still in learning/relearning, no
            // day-based schedule yet. Matches ts-fsrs basic_scheduler.ts:82.
            card.state = learningState
            card.step = targetStep
            card.scheduledDays = 0
            card.due = now.addingTimeInterval(duration)
        }
    }

    /// Schedule a Hard rating against the given learning/relearning steps.
    ///
    /// Hard in ts-fsrs stays on the current step (`next_step = cur_step`) but
    /// uses the step-independent `getHardInterval` duration. When the steps
    /// array is empty or the current step is out of range, ts-fsrs returns
    /// an empty strategy object which routes through the FSRS-interval
    /// graduation branch; we mirror that by calling ``graduate(_:stability:now:)``.
    private func applyHard(
        currentStep: Int,
        steps: [TimeInterval],
        stability: Double,
        to card: inout Card,
        now: Date,
        learningState: CardState
    ) {
        if steps.isEmpty || currentStep >= steps.count {
            graduate(&card, stability: stability, now: now)
            return
        }
        applyCustomDuration(hardIntervalMinutes(steps: steps),
                            targetStep: currentStep, to: &card, now: now,
                            learningState: learningState)
    }

    /// Step-independent Hard duration, matching ts-fsrs `getHardInterval`
    /// (strategies/learning_steps.ts:50-56).
    ///
    /// For single-step configs, returns `round(steps[0] * 1.5)` minutes.
    /// For multi-step configs, returns the rounded average of the first
    /// two steps. Returns 0 if the steps array is empty.
    ///
    /// Rounding uses the JS `Math.round` rule (half rounds away from zero
    /// for positive values), so a 5-minute single step yields 8 minutes
    /// (7.5 → 8), not 7.
    private func hardIntervalMinutes(steps: [TimeInterval]) -> TimeInterval {
        guard !steps.isEmpty else { return 0 }
        if steps.count == 1 {
            let minutes = steps[0] / 60.0
            let rounded = (minutes * 1.5).rounded(.toNearestOrAwayFromZero)
            return rounded * 60.0
        }
        let first = steps[0] / 60.0
        let second = steps[1] / 60.0
        let avg = ((first + second) / 2.0).rounded(.toNearestOrAwayFromZero)
        return avg * 60.0
    }

    /// Build a deterministic fuzz seed from card state + review time.
    ///
    /// Format mirrors ts-fsrs `DefaultInitSeedStrategy`: `${ms}_${reps}_${D*S}`.
    /// The `reps` component uses `card.reps + 1` because ts-fsrs pre-bumps
    /// `reps` in `AbstractScheduler.init()` before the seed is built, so
    /// the seed reflects the post-review rep count. Matching that closes the
    /// only remaining *structural* divergence from ts-fsrs's fuzz stream.
    /// (Double formatting still differs from JS `Number.toString()`, so
    /// byte-parity of the seed string is not guaranteed — Swift-internal
    /// determinism is the contract.)
    private func fuzzSeed(card: Card, now: Date) -> String {
        let timeMs = Int(now.timeIntervalSince1970 * 1000)
        let mul = card.difficulty * card.stability
        return "\(timeMs)_\(card.reps + 1)_\(mul)"
    }

    /// Graduate a card to the Review state with an FSRS-computed interval.
    private func graduate(_ card: inout Card, stability: Double, now: Date) {
        let interval = algorithm.nextInterval(stability: stability)
        card.state = .review
        card.step = 0
        card.scheduledDays = interval
        card.due = now.addingTimeInterval(Double(interval) * 86400.0)
    }

    private func makeLog(
        rating: Rating,
        card: Card,
        elapsedDays: Int,
        now: Date
    ) -> ReviewLog {
        ReviewLog(
            rating: rating,
            state: card.state,
            stability: card.stability,
            difficulty: card.difficulty,
            elapsedDays: elapsedDays,
            scheduledDays: card.scheduledDays,
            reviewedAt: now,
            previousDue: card.due,
            previousLastReview: card.lastReview,
            previousStep: card.step
        )
    }

    private func buildResult(
        _ outcome: (Rating) -> RecordLogItem
    ) -> SchedulingResult {
        SchedulingResult(
            again: outcome(.again),
            hard: outcome(.hard),
            good: outcome(.good),
            easy: outcome(.easy)
        )
    }
}
