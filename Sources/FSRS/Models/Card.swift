import Foundation

/// A flashcard's scheduling state.
///
/// `Card` is a value type that captures everything FSRS needs to compute
/// the next review interval. Create new cards with ``FSRS/createCard(now:)``
/// and advance them through reviews with ``FSRS/schedule(card:now:rating:)``.
public struct Card: Sendable, Codable, Equatable {
    /// When this card is next due for review.
    public var due: Date

    /// Memory stability (S) — the interval in days at which retrievability equals 90%.
    public var stability: Double

    /// Intrinsic difficulty (D) — ranges from 1.0 (easiest) to 10.0 (hardest).
    public var difficulty: Double

    /// Current position in the state machine.
    public var state: CardState

    /// Current index in the learning/relearning step sequence.
    /// Only meaningful when `state` is `.learning` or `.relearning`.
    public var step: Int

    /// Total number of reviews performed on this card.
    public var reps: Int

    /// Number of times this card lapsed (rated Again while in review).
    public var lapses: Int

    /// The integer-day interval assigned by the scheduler at the last review.
    ///
    /// Set by the scheduler each time `due` is set: for FSRS-interval reviews
    /// this is the day count returned by the algorithm; for long-step
    /// graduations (≥ 1 day learning steps that route to Review) it is the
    /// floor of the step duration in days; for in-day (re)learning steps it
    /// is 0 because the card is not yet on a day-based schedule.
    ///
    /// Returns 0 for new cards (never scheduled).
    public var scheduledDays: Int

    /// When this card was last reviewed. `nil` for new cards.
    public var lastReview: Date?

    /// Creates a new card in the `.new` state.
    public init(due: Date = Date()) {
        self.due = due
        self.stability = 0
        self.difficulty = 0
        self.state = .new
        self.step = 0
        self.reps = 0
        self.lapses = 0
        self.scheduledDays = 0
        self.lastReview = nil
    }

    /// Custom `Codable` decoder to keep backward compatibility with payloads
    /// written before `scheduledDays` was stored (it used to be computed).
    ///
    /// When the field is absent, we reconstruct the legacy formula
    /// `Int((due - lastReview) / 86400)`, clamped to ≥ 0. If `lastReview` is
    /// nil (new cards), we fall back to 0. Encoding stays auto-synthesized.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.due = try container.decode(Date.self, forKey: .due)
        self.stability = try container.decode(Double.self, forKey: .stability)
        self.difficulty = try container.decode(Double.self, forKey: .difficulty)
        self.state = try container.decode(CardState.self, forKey: .state)
        self.step = try container.decode(Int.self, forKey: .step)
        self.reps = try container.decode(Int.self, forKey: .reps)
        self.lapses = try container.decode(Int.self, forKey: .lapses)
        self.lastReview = try container.decodeIfPresent(Date.self, forKey: .lastReview)

        if let stored = try container.decodeIfPresent(Int.self, forKey: .scheduledDays) {
            self.scheduledDays = stored
        } else if let lastReview = self.lastReview {
            // Legacy fallback: reconstruct from (due - lastReview), floored and
            // clamped to non-negative to match the old computed property.
            self.scheduledDays = max(0, Int(self.due.timeIntervalSince(lastReview) / 86_400.0))
        } else {
            self.scheduledDays = 0
        }
    }

    /// The number of whole UTC calendar days between the last review and `now`.
    ///
    /// Matches ts-fsrs's `dateDiffInDays` (help.ts:223-237): the difference is
    /// the number of midnight-UTC boundaries crossed, not elapsed seconds. So
    /// a review at 23:00 UTC followed by one at 01:00 UTC the next day returns
    /// 1 (two hours elapsed, one boundary crossed), while reviews 11 hours
    /// apart on the same UTC date return 0.
    ///
    /// Returns 0 for new cards (no prior review) and for timestamps that are
    /// earlier than `lastReview` (negatives are clamped to 0).
    public func elapsedDays(now: Date) -> Int {
        guard let lastReview else { return 0 }
        let secondsPerDay: TimeInterval = 86_400
        // Floor each timestamp to its UTC-day start by stripping the intra-day
        // remainder. This mirrors `Date.UTC(year, month, day)` in JS.
        let lastUTCDay = floor(lastReview.timeIntervalSince1970 / secondsPerDay)
        let nowUTCDay = floor(now.timeIntervalSince1970 / secondsPerDay)
        return max(0, Int(nowUTCDay - lastUTCDay))
    }
}
