# swift-fsrs

A native Swift implementation of [FSRS v6](https://github.com/open-spaced-repetition/fsrs4anki/wiki/The-Algorithm) — the modern spaced-repetition algorithm used by Anki, RemNote, and many other flashcard systems. Pure Swift, zero dependencies, byte-parity verified against the canonical TypeScript reference.

> **Status:** Algorithm and scheduler are byte-parity verified against [ts-fsrs](https://github.com/open-spaced-repetition/ts-fsrs) v6 across 216 tests. Not yet 1.0 — APIs may shift before tagging stable. **This is an unofficial port** and is not affiliated with the [open-spaced-repetition](https://github.com/open-spaced-repetition) organization.

## Why this exists

If you're building a flashcard app for iOS/macOS/visionOS and want FSRS scheduling, your previous options were:

1. **Embed JavaScriptCore + ts-fsrs** — heavy, indirect, no Swift type safety.
2. **FFI into a Rust binary** ([fsrs-rs](https://github.com/open-spaced-repetition/fsrs-rs)) — build complexity, no native `Sendable` story, awkward across platforms.
3. **Roll your own** — error-prone; the algorithm has subtle edge cases that take time to discover the hard way.

`swift-fsrs` gives you a fourth option: a faithful native port written in modern Swift, with the actual ts-fsrs reference values asserted in tests so you can be confident the math matches.

## Inspiration and Attribution

This package is a port — almost all credit belongs upstream:

- **[ts-fsrs](https://github.com/open-spaced-repetition/ts-fsrs)** by [@ishiko732](https://github.com/ishiko732) and contributors is the canonical TypeScript reference. Every formula, scheduler decision, rounding site, and edge case in this Swift port traces back to ts-fsrs. The 216 parity tests are anchored on hardcoded reference values lifted directly from `ts-fsrs/packages/fsrs/__tests__/`. If something looks weirdly precise here, it's because ts-fsrs got there first.
- **[fsrs-rs](https://github.com/open-spaced-repetition/fsrs-rs)** by [@asukaminato0721](https://github.com/asukaminato0721), [@L-M-Sherlock](https://github.com/L-M-Sherlock) and contributors is the canonical Rust port and the FSRS optimizer/trainer. swift-fsrs deliberately does **not** include the optimizer (see "Scope" below); if you want to train weights from review history, fsrs-rs is the reference implementation.
- **The FSRS algorithm itself** was designed by [Jarrett Ye](https://github.com/L-M-Sherlock) and the FSRS research community. Read the [algorithm wiki](https://github.com/open-spaced-repetition/fsrs4anki/wiki/The-Algorithm) for the math behind the formulas this package implements.

If this Swift port is useful to you, consider [starring ts-fsrs](https://github.com/open-spaced-repetition/ts-fsrs) and supporting the upstream FSRS project — they did the hard work.

## Install

Swift Package Manager:

```swift
.package(url: "https://github.com/<your-username>/swift-fsrs.git", from: "0.1.0")
```

Then add `"FSRS"` to your target dependencies. Requires Swift 6.2 / Xcode 26 or later.

## Quick start

```swift
import FSRS

let fsrs = FSRS()                     // default v6 weights
var card = FSRS.createCard()          // a brand-new card, due immediately

// User reviews the card; you decide the rating from response time, errors, etc.
let result = fsrs.schedule(card: card, now: Date(), rating: .good)

card = result.card                    // updated state — persist this
let log = result.log                  // a record of the review — persist this too

print(card.due)                       // when to show the card next
print(card.state)                     // .new / .learning / .review / .relearning
print(fsrs.retrievability(of: card))  // estimated recall probability right now
```

That's the entire scheduling cycle. FSRS computes the `due` date; you query for `due <= Date()` cards in the next session.

## Concepts (60-second tour)

- **`Card`** — a value type holding the per-card scheduling state: `due`, `stability`, `difficulty`, `state`, `step`, `reps`, `lapses`, `scheduledDays`, `lastReview`. It does **not** hold your card content (front/back) — wire that up in your own model with a card ID.
- **`Rating`** — `.again` / `.hard` / `.good` / `.easy`. You decide how to derive these from user input (response time, error count, self-grading button, etc.).
- **`FSRS`** — the scheduler. `init(parameters:)` accepts default v6 weights or a custom `Parameters` (e.g., weights from an FSRS optimizer trained on your users' data).
- **`SchedulingResult`** — what `schedule(card:now:)` returns: previews of all four ratings (`again`, `hard`, `good`, `easy`), each a `RecordLogItem { card, log }`. Use this to show "1m / 6m / 10m / 15m" buttons before the user picks.
- **`ReviewLog`** — an immutable snapshot of one review event. Persist these for history, undo, and (eventually) feeding into an optimizer pipeline.

## API surface

```swift
public struct FSRS: Sendable {
    init(parameters: Parameters = Parameters())
    static func createCard(now: Date = Date()) -> Card

    func schedule(card: Card, now: Date = Date()) -> SchedulingResult
    func schedule(card: Card, now: Date = Date(), rating: Rating) -> RecordLogItem

    func retrievability(of card: Card, now: Date = Date()) -> Double

    func rollback(card: Card, log: ReviewLog) -> Card
    func forget(card: Card, now: Date = Date(), resetCount: Bool = false) -> RecordLogItem
}
```

- `schedule(card:now:)` returns all four rating outcomes for previewing in your UI.
- `schedule(card:now:rating:)` is the convenience overload when you already know the rating.
- `rollback` undoes a review — for an "undo" button. Pass the same `ReviewLog` you got from `schedule`.
- `forget` resets a card to `.new` — for a "really forgot, start over" button.

## Two scheduler modes

```swift
// Basic (default) — new cards step through learning intervals (1m, 10m by default)
//                   before graduating to FSRS-computed intervals.
let basic = FSRS()

// Long-term — every review immediately produces an FSRS interval, no learning steps.
let longTerm = FSRS(parameters: Parameters(enableShortTerm: false))
```

Use **basic** for an Anki-style flow with quick relearning loops. Use **long-term** when you want FSRS to control intervals from the very first review (often preferred for less tactile inputs like web apps).

## Custom parameters (optimizer-trained weights)

The 21 default weights are pre-trained on a large aggregate dataset and work well for most users. If you run the FSRS optimizer ([fsrs-rs](https://github.com/open-spaced-repetition/fsrs-rs) or the [Python optimizer](https://github.com/open-spaced-repetition/fsrs-optimizer)) on your own review data, plug the result in:

```swift
let myWeights = Weights(array: [/* 21 values from the optimizer */])
let fsrs = FSRS(parameters: Parameters(weights: myWeights))
```

You can also tune `requestRetention`, `maximumInterval`, `learningSteps`, `relearningSteps`, `enableShortTerm`, and `enableFuzz` on `Parameters`.

## Scope (what's included, what isn't)

### Included
- The full FSRS v6 algorithm (`forgettingCurve`, `nextDifficulty`, `nextRecallStability`, `nextForgetStability`, `nextShortTermStability`, `nextState`, `nextInterval`).
- `BasicScheduler` and `LongTermScheduler`, both byte-parity verified.
- Interval fuzzing with a deterministic seeded PRNG (Alea, byte-for-byte ported from JS).
- `rollback` and `forget` for undo / reset UX.
- `Codable` on `Card`, `ReviewLog`, and `RecordLogItem` for trivial persistence — with a backward-compat decoder for `Card.scheduledDays` so existing JSON keeps working when you upgrade.

### Deliberately not included
- **`reschedule(card, reviews, options)`** — replays a card's full history under new weights. Useful only after retraining the optimizer; most apps don't need it. PRs welcome with use-case discussion.
- **`Rating.manual` (5th rating value)** — ts-fsrs uses it to tag forget/reschedule logs. Adding it to Swift's exhaustive `Rating` enum is invasive and provides no user-visible behavior. Swift's `forget` log uses `.again` as a stand-in (documented in source).
- **Strategy hooks (`useStrategy(SCHEDULER/SEED/LEARNING_STEPS, ...)`)** — ts-fsrs's plug-in mechanism for custom schedulers, RNG seeds, learning-step strategies. Skipped to keep the surface simple.
- **The optimizer / training pipeline** — that's [fsrs-rs](https://github.com/open-spaced-repetition/fsrs-rs)'s job. Train weights there (Python or Rust), then load them into swift-fsrs at runtime.
- **`migrateParameters`** — auto-upgrade FSRS-4 (17 weights) or FSRS-5 (19 weights) inputs to v6 (21 weights). On the roadmap; for now, only FSRS-6 weights are accepted.
- **Loose date-input types** (`Date | number | string` like ts-fsrs) — Swift's type system makes this needlessly noisy. Use `Date` everywhere.

If any of these matter for your use case, [open an issue](#contributing) — most are tractable, they're just not in v0.x.

## Verification (why you can trust the math)

- **216 tests across 57 suites**, all passing.
- The four `*ParityTests.swift` files cross-check Swift output against ts-fsrs's own test suite at `packages/fsrs/__tests__/`. Reference values are taken **verbatim** from there — they're computed and asserted by the ts-fsrs maintainers, so they're our ground truth.
- Every parity assertion uses exact `==` (no tolerance), except 4 assertions that mirror ts-fsrs's own `toBeCloseTo(... 4)` precision on its memory-state finals.
- Sequence A canary: after a new card receives Good at t=0 and Good again at t=2 days, `card.stability == 10.96433194` and `card.difficulty == 2.11121424` — both exact, locked in tests.
- The [Alea PRNG](Sources/FSRS/Alea.swift) (used by interval fuzzing) is a byte-for-byte port of the JS implementation, verified by 5 reference vectors that match ts-fsrs bit-exact.
- Coverage matrix: every `(state × rating)` cell for both schedulers is asserted byte-exact. Long sequences of 50 mixed-rating reviews drift zero from the reference.

Run the suite locally:

```bash
swift test
```

## Concurrency

Swift 6.2 strict concurrency is on. Everything public is `Sendable`:

- `FSRS`, `Parameters`, `Weights`, `Card`, `ReviewLog`, `RecordLogItem`, `SchedulingResult` — all value types.
- No actors, no locks, no mutable shared state. Multiple `FSRS` instances can run on different threads concurrently with no synchronization needed.

## Roadmap

In rough priority order:

- [ ] `migrateParameters` (FSRS-4/5 → v6 weight migration)
- [ ] DocC catalog + hosted documentation
- [ ] CI badge (GitHub Actions on macOS / Linux)
- [ ] An `Examples/` directory with a minimal SwiftUI flashcard sample
- [ ] `reschedule` (only if there's demand)

## Contributing

Issues, bug reports, and PRs are welcome. Two ground rules before contributing:

1. **ts-fsrs is canonical.** If a Swift change would diverge from ts-fsrs's output, it needs a strong justification. The 216 parity tests are the regression net — don't weaken assertions to make a change pass.
2. **Run `swift test` before opening a PR.** Test count must stay ≥ 216, all passing, with clean build (zero warnings).

For internal architecture rules and the "do not touch" list, see [`CLAUDE.md`](CLAUDE.md).

## Acknowledgments

- [Jarrett Ye](https://github.com/L-M-Sherlock) and the FSRS research community for designing the algorithm.
- [@ishiko732](https://github.com/ishiko732) and the [ts-fsrs](https://github.com/open-spaced-repetition/ts-fsrs) contributors — this port would not be possible without their reference implementation and exhaustive test suite.
- The [open-spaced-repetition](https://github.com/open-spaced-repetition) organization for stewarding the FSRS ecosystem in the open.
