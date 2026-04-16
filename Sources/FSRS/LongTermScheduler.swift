import Foundation

/// Scheduler that skips learning steps entirely.
///
/// Every review — regardless of current state — goes directly to the
/// `review` state with an FSRS-computed interval. Used when
/// `Parameters.enableShortTerm` is `false`.
///
/// Simpler than ``BasicScheduler`` but produces longer initial intervals
/// (no 1-minute / 10-minute warmup for new cards).
struct LongTermScheduler: Sendable {

    let algorithm: FSRSAlgorithm
    let parameters: Parameters

    func schedule(card: Card, now: Date) -> SchedulingResult {
        let t = card.elapsedDays(now: now)

        // Compute FSRS state for all 4 ratings
        var states = [(Rating, Double, Double)]()  // (rating, newS, newD)
        for rating in Rating.allCases {
            let (newS, newD) = algorithm.nextState(
                stability: card.stability,
                difficulty: card.difficulty,
                elapsedDays: t,
                rating: rating
            )
            states.append((rating, newS, newD))
        }

        // Compute raw intervals
        var intervals: [Rating: Int] = [:]
        for (rating, newS, _) in states {
            intervals[rating] = algorithm.nextInterval(stability: newS)
        }

        // Enforce strict ordering: again < hard < good < easy. ts-fsrs caps
        // Again at Hard *first*, then bumps each higher rating above the
        // previous by at least one day. See long_term_scheduler.ts:112-115.
        var againI = intervals[.again]!
        var hardI = intervals[.hard]!
        againI = min(againI, hardI)
        hardI = max(hardI, againI + 1)
        let goodI = max(intervals[.good]!, hardI + 1)
        let easyI = max(intervals[.easy]!, goodI + 1)

        var ordered: [Rating: Int] = [
            .again: againI, .hard: hardI, .good: goodI, .easy: easyI,
        ]

        // Apply fuzz if enabled
        if parameters.enableFuzz {
            // Seed mirrors ts-fsrs `DefaultInitSeedStrategy` (seed.ts):
            // `${review_time_ms}_${reps}_${D*S}`. Swift's Double formatting
            // differs slightly from JS `Number.toString()` (e.g. "5.0" vs "5"),
            // so our seed strings are NOT byte-identical to ts-fsrs — we only
            // guarantee Swift-internal determinism (same inputs → same output).
            let seed = fuzzSeed(card: card, now: now)
            for rating in Rating.allCases {
                ordered[rating] = IntervalFuzzer.fuzz(
                    interval: ordered[rating]!,
                    elapsedDays: t,
                    maximumInterval: parameters.maximumInterval,
                    seed: seed
                )
            }
        }

        // Build results
        func makeItem(rating: Rating) -> RecordLogItem {
            let (_, newS, newD) = states.first { $0.0 == rating }!
            let interval = ordered[rating]!

            var newCard = card
            newCard.stability = newS
            newCard.difficulty = newD
            newCard.state = .review
            newCard.step = 0
            newCard.reps += 1
            newCard.lastReview = now
            newCard.scheduledDays = interval
            newCard.due = now.addingTimeInterval(Double(interval) * 86400.0)

            // Increment lapses on Again for any non-New prior state. In
            // ts-fsrs, `learningState` delegates to `reviewState`, which
            // unconditionally increments `next_again.lapses` — but the first
            // review of a brand-new card (state == .new) takes the `newState`
            // branch where lapses stay at zero. See long_term_scheduler.ts:64-88.
            if rating == .again && card.state != .new {
                newCard.lapses += 1
            }

            let log = ReviewLog(
                rating: rating,
                state: card.state,
                stability: card.stability,
                difficulty: card.difficulty,
                elapsedDays: t,
                scheduledDays: card.scheduledDays,
                reviewedAt: now,
                previousDue: card.due,
                previousLastReview: card.lastReview,
                previousStep: card.step
            )

            return RecordLogItem(card: newCard, log: log)
        }

        return SchedulingResult(
            again: makeItem(rating: .again),
            hard: makeItem(rating: .hard),
            good: makeItem(rating: .good),
            easy: makeItem(rating: .easy)
        )
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
}
