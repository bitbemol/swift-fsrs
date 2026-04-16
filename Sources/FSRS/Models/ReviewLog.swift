import Foundation

/// A record of a single review event.
///
/// Captures the card's state *before* the review and the rating applied.
/// Useful for review history analysis and for ``FSRS/rollback(card:log:)``.
///
/// > Note: Swift's `ReviewLog` semantics differ from ts-fsrs. ts-fsrs's
/// > `buildLog` populates `state`, `stability`, `difficulty`, and
/// > `scheduled_days` with the *post-review* values from `this.current`,
/// > whereas Swift's schedulers populate them with the *pre-review* values
/// > from the input card. The Swift semantics are more useful for rollback
/// > (we restore directly from the log) and the choice is locked in by
/// > the existing `Log captures pre-review state` test. If you ever feed
/// > Swift logs into a ts-fsrs-compatible optimizer pipeline, note this
/// > divergence in the field meanings.
public struct ReviewLog: Sendable, Codable, Equatable {
    /// The rating the user assigned during this review.
    public let rating: Rating

    /// The card's state *before* this review was applied.
    public let state: CardState

    /// The card's stability before this review.
    public let stability: Double

    /// The card's difficulty before this review.
    public let difficulty: Double

    /// Days elapsed since the previous review at the time of this review.
    /// Counted as UTC calendar-day boundaries crossed (see ``Card/elapsedDays(now:)``).
    public let elapsedDays: Int

    /// The number of days that were scheduled for this interval, as held by
    /// the card *before* the review.
    public let scheduledDays: Int

    /// When this review occurred.
    public let reviewedAt: Date

    /// The card's `due` *before* the review. Required by ``FSRS/rollback(card:log:)``
    /// to restore the original due date for cards that were in the `.new` state
    /// (where there is no `previousLastReview` to fall back to).
    public let previousDue: Date

    /// The card's `lastReview` *before* the review. `nil` if the card had never
    /// been reviewed (pre-review state was `.new`). Used by ``FSRS/rollback(card:log:)``
    /// to restore the card's review timeline.
    public let previousLastReview: Date?

    /// The card's `step` *before* the review. Only meaningful when the
    /// pre-review state was `.learning` or `.relearning`. Used by
    /// ``FSRS/rollback(card:log:)`` to restore the in-progress step index.
    public let previousStep: Int
}

/// A card paired with the review log entry that produced it.
///
/// Returned by scheduling operations to provide both the updated card
/// state and a record of the review that was applied.
public struct RecordLogItem: Sendable, Codable, Equatable {
    /// The card after the review was applied.
    public let card: Card

    /// The log entry recording this review.
    public let log: ReviewLog
}
