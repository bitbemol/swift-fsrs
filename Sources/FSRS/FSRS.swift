import Foundation

/// FSRS v6 spaced repetition scheduler.
///
/// The entry point for scheduling flashcard reviews. Computes optimal
/// review intervals using a 21-parameter model of human memory.
///
/// ## Quick Start
///
/// ```swift
/// let fsrs = FSRS()
/// var card = FSRS.createCard()
///
/// // Show the card and get the user's rating
/// let result = fsrs.schedule(card: card, now: Date(), rating: .good)
/// card = result.card
/// // card.due is when to show it next
/// ```
///
/// ## Scheduler Modes
///
/// - **Basic** (default, `enableShortTerm: true`): New cards progress
///   through learning steps (1m, 10m by default) before graduating to
///   FSRS intervals. Lapsed cards go through relearning steps.
///
/// - **Long-term** (`enableShortTerm: false`): Every review immediately
///   produces an FSRS-computed interval. No learning steps.
///
/// ## Custom Parameters
///
/// The 21 default weights are pre-trained on aggregate review data. To use
/// weights optimized for your personal review history, run the FSRS
/// optimizer (Python or Rust) and pass the result:
///
/// ```swift
/// let myWeights = Weights(array: [/* 21 values from optimizer */])
/// let fsrs = FSRS(parameters: Parameters(weights: myWeights))
/// ```
public struct FSRS: Sendable {

    /// The parameters used by this scheduler instance.
    public let parameters: Parameters

    private let algorithm: FSRSAlgorithm

    /// Creates a new FSRS scheduler with the given parameters.
    ///
    /// - Parameter parameters: Scheduler configuration. Uses FSRS v6
    ///   defaults if not specified.
    public init(parameters: Parameters = Parameters()) {
        self.parameters = parameters
        self.algorithm = FSRSAlgorithm(parameters: parameters)
    }

    // MARK: - Card Factory

    /// Creates a new card in the `.new` state, due immediately.
    ///
    /// - Parameter now: The creation time. Defaults to the current date.
    /// - Returns: A card ready for its first review.
    public static func createCard(now: Date = Date()) -> Card {
        Card(due: now)
    }

    // MARK: - Scheduling

    /// Computes scheduling outcomes for all four ratings.
    ///
    /// Returns a ``SchedulingResult`` containing the card state and review
    /// log that would result from each possible rating. Use this to display
    /// the next due date for each button before the user chooses.
    ///
    /// - Parameters:
    ///   - card: The card to schedule.
    ///   - now: The current time. Defaults to `Date()`.
    /// - Returns: Outcomes for Again, Hard, Good, and Easy.
    public func schedule(card: Card, now: Date = Date()) -> SchedulingResult {
        if parameters.enableShortTerm {
            BasicScheduler(algorithm: algorithm, parameters: parameters)
                .schedule(card: card, now: now)
        } else {
            LongTermScheduler(algorithm: algorithm, parameters: parameters)
                .schedule(card: card, now: now)
        }
    }

    /// Computes the scheduling outcome for a specific rating.
    ///
    /// Convenience method when you only need one outcome. Equivalent to
    /// `schedule(card:now:)[rating]`.
    ///
    /// - Parameters:
    ///   - card: The card to schedule.
    ///   - now: The current time. Defaults to `Date()`.
    ///   - rating: The user's recall rating.
    /// - Returns: The updated card and a review log entry.
    public func schedule(card: Card, now: Date = Date(), rating: Rating) -> RecordLogItem {
        schedule(card: card, now: now)[rating]
    }

    // MARK: - Retrievability

    /// The estimated probability that the user can recall the card right now.
    ///
    /// Returns 0 for new cards (never reviewed). For reviewed cards, uses
    /// the FSRS v6 forgetting curve:
    ///
    /// `R(t, S) = (1 + factor × t / S) ^ decay`
    ///
    /// - Parameters:
    ///   - card: The card to query.
    ///   - now: The current time. Defaults to `Date()`.
    /// - Returns: Retrievability in [0, 1], or 0 for unreviewed cards.
    public func retrievability(of card: Card, now: Date = Date()) -> Double {
        guard card.state != .new, card.stability >= FSRSAlgorithm.sMin else {
            return 0
        }
        // Elapsed days is an integer (UTC calendar-day boundaries crossed);
        // cast to Double at the call site since the forgetting curve is
        // defined on real-valued time.
        let t = card.elapsedDays(now: now)
        return algorithm.forgettingCurve(elapsedDays: Double(t), stability: card.stability)
    }

    // MARK: - Rollback

    /// Undoes a review, returning the card to the state it was in before the review.
    ///
    /// Use this to implement an "undo" button: when the user realizes they
    /// hit the wrong rating, pass them the post-review card and the log
    /// emitted by ``schedule(card:now:rating:)`` to recover the prior state.
    ///
    /// The rolled-back card restores `stability`, `difficulty`, `state`,
    /// `step`, `scheduledDays`, and `lastReview` from the log, decrements
    /// `reps` by one, and conditionally decrements `lapses` (see below).
    /// The `due` is set to:
    /// - the *original* due of the new card, when rolling back from `.new`
    ///   (since the rolled-back card has no last-review timeline to "wait from"),
    /// - the time the rollbacked review happened (`log.reviewedAt`) otherwise,
    ///   so the card is immediately due again from the user's perspective.
    ///
    /// Matches `fsrs.ts:rollback` (ts-fsrs).
    ///
    /// > Important: `lapses` is only decremented when `log.state == .review`
    /// > and the rating was `.again`. This mirrors ts-fsrs verbatim. In
    /// > long-term mode (``Parameters/enableShortTerm`` = `false`),
    /// > ``LongTermScheduler`` also increments lapses for Again on Learning
    /// > or Relearning cards, but rollback will not undo those increments
    /// > — this is a known divergence from "exactly correct" lapse accounting,
    /// > deliberately preserved for ts-fsrs parity.
    ///
    /// - Parameters:
    ///   - card: The card *after* the review you want to undo.
    ///   - log: The review log produced by the scheduling call you want to undo.
    /// - Returns: The card as it was before the review.
    public func rollback(card: Card, log: ReviewLog) -> Card {
        var rolled = card
        rolled.state = log.state
        rolled.stability = log.stability
        rolled.difficulty = log.difficulty
        rolled.scheduledDays = log.scheduledDays
        rolled.step = log.previousStep
        rolled.reps = max(0, card.reps - 1)

        if log.state == .new {
            rolled.due = log.previousDue
            rolled.lastReview = nil
            rolled.lapses = 0
        } else {
            rolled.due = log.reviewedAt
            rolled.lastReview = log.previousLastReview
            let didIncrementLapse = log.rating == .again && log.state == .review
            rolled.lapses = max(0, card.lapses - (didIncrementLapse ? 1 : 0))
        }
        return rolled
    }

    // MARK: - Forget

    /// Resets a card to the `.new` state, optionally clearing review counters.
    ///
    /// Use this when the user marks a card as completely forgotten and wants
    /// it back at the start of the learning pipeline. Stability and
    /// difficulty are reset to zero, the step is cleared, and the card is
    /// immediately due. `lastReview` is preserved (matching ts-fsrs) so the
    /// card retains its history timestamp even though it's logically "new".
    ///
    /// `reps` and `lapses` are preserved by default. Pass `resetCount: true`
    /// to zero them as well — useful when treating the card as truly new.
    ///
    /// Matches `fsrs.ts:forget` (ts-fsrs).
    ///
    /// > Important: ts-fsrs tags forget log entries with `Rating.Manual`,
    /// > a fifth rating value not present in Swift's ``Rating`` enum. The
    /// > returned ``ReviewLog`` uses ``Rating/again`` as a stand-in. As a
    /// > consequence, the forget log is **not** safe input to
    /// > ``rollback(card:log:)`` — passing it will produce an inconsistent
    /// > card (e.g., spurious lapse decrements). Treat the log as an
    /// > audit-trail entry, not a reversible review event.
    ///
    /// - Parameters:
    ///   - card: The card to forget.
    ///   - now: The time of the operation. Defaults to `Date()`.
    ///   - resetCount: Whether to also reset `reps` and `lapses` to zero.
    ///     Defaults to `false`.
    /// - Returns: The forgotten card paired with an audit log entry.
    public func forget(
        card: Card,
        now: Date = Date(),
        resetCount: Bool = false
    ) -> RecordLogItem {
        // ts-fsrs forget computes scheduled_days = date_diff(now, card.due, 'days')
        // for non-new cards, 0 otherwise. Mirror Card.elapsedDays's UTC-day
        // floor (which matches dateDiffInDays in ts-fsrs help.ts) on (now, due)
        // and clamp negatives to 0 — early forgets shouldn't yield negatives in
        // an audit record.
        let scheduledDaysAtForget: Int
        if card.state == .new {
            scheduledDaysAtForget = 0
        } else {
            let secondsPerDay: TimeInterval = 86_400
            let dueDay = floor(card.due.timeIntervalSince1970 / secondsPerDay)
            let nowDay = floor(now.timeIntervalSince1970 / secondsPerDay)
            scheduledDaysAtForget = max(0, Int(nowDay - dueDay))
        }

        var forgotten = card
        forgotten.due = now
        forgotten.stability = 0
        forgotten.difficulty = 0
        forgotten.scheduledDays = 0
        forgotten.step = 0
        forgotten.state = .new
        if resetCount {
            forgotten.reps = 0
            forgotten.lapses = 0
        }
        // forgotten.lastReview is intentionally preserved (matches ts-fsrs).

        let log = ReviewLog(
            rating: .again,  // Stand-in for ts-fsrs Rating.Manual; see doc note above.
            state: card.state,
            stability: card.stability,
            difficulty: card.difficulty,
            elapsedDays: 0,
            scheduledDays: scheduledDaysAtForget,
            reviewedAt: now,
            previousDue: card.due,
            previousLastReview: card.lastReview,
            previousStep: card.step
        )

        return RecordLogItem(card: forgotten, log: log)
    }
}
