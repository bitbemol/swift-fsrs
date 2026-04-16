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
}
