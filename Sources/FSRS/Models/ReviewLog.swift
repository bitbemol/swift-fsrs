import Foundation

/// A record of a single review event.
///
/// Captures the card's state *before* the review and the rating applied.
/// Useful for review history analysis and potential future optimization.
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

    /// The number of days that were scheduled for this interval.
    public let scheduledDays: Int

    /// When this review occurred.
    public let reviewedAt: Date
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
