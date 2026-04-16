/// The current learning state of a card in the FSRS state machine.
///
/// Cards progress through states as they are reviewed:
/// - `new` → `learning` → `review`
/// - `review` → `relearning` (on lapse) → `review`
public enum CardState: Int, Sendable, Codable, CustomStringConvertible {
    /// Card has never been reviewed.
    case new = 0
    /// Card is being learned for the first time (short intervals).
    case learning = 1
    /// Card is in the regular review cycle (FSRS-computed intervals).
    case review = 2
    /// Card was forgotten and is being re-learned (short intervals).
    case relearning = 3

    public var description: String {
        switch self {
        case .new: "New"
        case .learning: "Learning"
        case .review: "Review"
        case .relearning: "Relearning"
        }
    }
}
