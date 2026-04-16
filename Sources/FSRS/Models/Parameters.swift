import Foundation

// MARK: - Weights

/// The 21 trainable parameters of the FSRS v6 algorithm.
///
/// Default values are pre-trained on aggregate review data. Users can supply
/// custom weights from the FSRS optimizer (Python/Rust) via ``init(array:)``.
///
/// ## Parameter groups
/// - **w\[0\]–w\[3\]**: Initial stability for each rating (Again → Easy)
/// - **w\[4\]–w\[7\]**: Difficulty model (initial value, slope, change rate, mean reversion)
/// - **w\[8\]–w\[10\]**: Stability after successful recall
/// - **w\[11\]–w\[14\]**: Stability after lapse (forgetting)
/// - **w\[15\]–w\[16\]**: Hard penalty and Easy bonus
/// - **w\[17\]–w\[18\]**: Short-term (same-day) stability
/// - **w\[19\]**: Short-term stability dampening (new in v6)
/// - **w\[20\]**: Forgetting curve decay (new in v6, was fixed 0.5 in v5)
public struct Weights: Sendable, Codable, Equatable {

    /// Number of parameters in FSRS v6.
    public static let count = 21

    /// The raw parameter array.
    public private(set) var values: [Double]

    /// FSRS v6 defaults, pre-trained on aggregate Anki review data.
    public static let `default` = Weights(array: [
        0.212, 1.2931, 2.3065, 8.2956,   // w[0]–w[3]: initial stability
        6.4133, 0.8334,                    // w[4]–w[5]: initial difficulty
        3.0194, 0.001,                     // w[6]–w[7]: difficulty dynamics
        1.8722, 0.1666, 0.796,            // w[8]–w[10]: recall stability
        1.4835, 0.0614, 0.2629, 1.6483,  // w[11]–w[14]: lapse stability
        0.6014, 1.8729,                    // w[15]–w[16]: hard penalty / easy bonus
        0.5425, 0.0912,                    // w[17]–w[18]: short-term stability
        0.0658,                            // w[19]: short-term dampening (v6)
        0.1542,                            // w[20]: forgetting curve decay (v6)
    ])

    /// Creates weights from a raw parameter array.
    ///
    /// - Parameter array: Must contain exactly 21 finite values. Values are
    ///   clamped to their valid ranges as defined by the FSRS v6 specification.
    /// - Precondition: `array.count == 21` and every value is finite (no NaN/Inf).
    public init(array: [Double]) {
        precondition(array.count == Self.count, "FSRS v6 requires exactly \(Self.count) weights, got \(array.count)")
        precondition(array.allSatisfy { $0.isFinite }, "FSRS weights must all be finite (no NaN or Inf)")
        self.values = array
        clampToValidRanges()
    }

    public subscript(index: Int) -> Double {
        get { values[index] }
        set {
            values[index] = newValue
            clampToValidRanges()
        }
    }

    // MARK: - Valid ranges per the FSRS v6 spec

    private static let ranges: [(ClosedRange<Double>)] = [
        0.001...100.0,   // w[0]: initial stability (Again)
        0.001...100.0,   // w[1]: initial stability (Hard)
        0.001...100.0,   // w[2]: initial stability (Good)
        0.001...100.0,   // w[3]: initial stability (Easy)
        1.0...10.0,      // w[4]: initial difficulty
        0.001...4.0,     // w[5]: initial difficulty slope
        0.001...4.0,     // w[6]: difficulty change rate
        0.001...0.75,    // w[7]: mean reversion weight
        0.0...4.5,       // w[8]: recall stability multiplier (exp)
        0.0...0.8,       // w[9]: recall stability S negative power
        0.001...3.5,     // w[10]: recall stability R exponent
        0.001...5.0,     // w[11]: lapse stability multiplier
        0.001...0.25,    // w[12]: lapse stability D negative power
        0.001...0.9,     // w[13]: lapse stability S power
        0.0...4.0,       // w[14]: lapse stability R exponent
        0.0...1.0,       // w[15]: hard penalty
        1.0...6.0,       // w[16]: easy bonus
        0.0...2.0,       // w[17]: short-term exponent
        0.0...2.0,       // w[18]: short-term rating offset
        0.0...0.8,       // w[19]: short-term dampening (v6)
        0.1...0.8,       // w[20]: forgetting curve decay (v6)
    ]

    private mutating func clampToValidRanges() {
        for i in values.indices {
            let range = Self.ranges[i]
            values[i] = min(max(values[i], range.lowerBound), range.upperBound)
        }
    }
}

// MARK: - Parameters

/// Configuration for the FSRS scheduler.
///
/// Controls retention targets, interval limits, learning steps, and the
/// 21 trainable weights that define the forgetting curve and stability model.
public struct Parameters: Sendable, Codable {

    /// Target probability of successful recall. Default: 0.9 (90%).
    /// Valid range: (0, 1). Lower values produce shorter intervals.
    public var requestRetention: Double

    /// Hard cap on scheduled intervals in days. Default: 36500 (≈100 years).
    public var maximumInterval: Int

    /// The 21 FSRS v6 algorithm weights.
    public var weights: Weights

    /// Whether to add randomness to computed intervals.
    /// When `true`, intervals are fuzzed within a small range to prevent
    /// cards with similar histories from clustering on the same day.
    public var enableFuzz: Bool

    /// Whether to use learning steps for new and re-learning cards.
    /// When `true` (default), uses ``learningSteps`` and ``relearningSteps``
    /// for short-interval progression before graduating to FSRS intervals.
    /// When `false`, every review goes directly to the Review state with
    /// FSRS-computed intervals (LongTermScheduler mode).
    public var enableShortTerm: Bool

    /// Step durations (in seconds) for learning new cards.
    /// Default: `[60, 600]` (1 minute, 10 minutes).
    public var learningSteps: [TimeInterval]

    /// Step durations (in seconds) for re-learning lapsed cards.
    /// Default: `[600]` (10 minutes).
    public var relearningSteps: [TimeInterval]

    public init(
        requestRetention: Double = 0.9,
        maximumInterval: Int = 36500,
        weights: Weights = .default,
        enableFuzz: Bool = false,
        enableShortTerm: Bool = true,
        learningSteps: [TimeInterval] = [60, 600],
        relearningSteps: [TimeInterval] = [600]
    ) {
        self.requestRetention = min(max(requestRetention, 0.01), 0.99)
        self.maximumInterval = max(1, maximumInterval)
        self.weights = weights
        self.enableFuzz = enableFuzz
        self.enableShortTerm = enableShortTerm
        self.learningSteps = learningSteps
        self.relearningSteps = relearningSteps

        applyContextDependentWeightRanges()
    }

    /// Applies the ranges that depend on `relearningSteps` and `enableShortTerm`.
    ///
    /// These cannot be applied at `Weights` construction because `Weights` has no
    /// knowledge of the scheduler context. ts-fsrs handles this in
    /// `clipParameters` which takes both `numRelearningSteps` and `enableShortTerm`.
    ///
    /// Dynamic rules:
    /// - When `relearningSteps.count > 1`, the upper bound for `w[17]` and `w[18]`
    ///   is reduced to prevent relearning steps from inflating stability above
    ///   pre-lapse S. Derived from the constraint
    ///   `num_relearning_steps * w17 * w18 + ln(w11) + ln(2^w13 - 1) + w14 * 0.3 <= 0`.
    /// - When `enableShortTerm == true`, the lower bound for `w[19]` is `0.01`
    ///   (otherwise `0.0`). This prevents `S^(-w[19])` from being the identity
    ///   during same-day reviews when short-term mode is active.
    private mutating func applyContextDependentWeightRanges() {
        let n = relearningSteps.count
        if n > 1 {
            let w = weights
            let numerator = -(log(w[11]) + log(pow(2.0, w[13]) - 1.0) + w[14] * 0.3)
            let dynamicCeiling = min(max(numerator / Double(n), 0.01), 2.0)
            if weights[17] > dynamicCeiling { weights[17] = dynamicCeiling }
            if weights[18] > dynamicCeiling { weights[18] = dynamicCeiling }
        }
        if enableShortTerm && weights[19] < 0.01 {
            weights[19] = 0.01
        }
    }
}
