/// The scheduling outcomes for all four possible ratings.
///
/// Returned by ``FSRS/schedule(card:now:)`` to let the caller present
/// all options to the user and apply whichever rating they choose.
public struct SchedulingResult: Sendable, Codable, Equatable {
    /// Outcome if the user rates the card as Again (complete failure).
    public let again: RecordLogItem

    /// Outcome if the user rates the card as Hard.
    public let hard: RecordLogItem

    /// Outcome if the user rates the card as Good.
    public let good: RecordLogItem

    /// Outcome if the user rates the card as Easy (instant recall).
    public let easy: RecordLogItem

    /// Access an outcome by rating.
    public subscript(rating: Rating) -> RecordLogItem {
        switch rating {
        case .again: again
        case .hard: hard
        case .good: good
        case .easy: easy
        }
    }
}
