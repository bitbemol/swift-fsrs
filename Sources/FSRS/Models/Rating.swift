/// User's self-assessed recall quality after reviewing a card.
///
/// Maps to grades 1–4 in the FSRS algorithm. Higher ratings indicate
/// better recall and produce longer intervals.
public enum Rating: Int, Sendable, Codable, CaseIterable, Comparable, CustomStringConvertible {
    /// Complete failure to recall. Card re-enters learning.
    case again = 1
    /// Recalled with significant difficulty.
    case hard = 2
    /// Recalled with acceptable effort.
    case good = 3
    /// Recalled instantly with no effort.
    case easy = 4

    public static func < (lhs: Rating, rhs: Rating) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var description: String {
        switch self {
        case .again: "Again"
        case .hard: "Hard"
        case .good: "Good"
        case .easy: "Easy"
        }
    }
}
