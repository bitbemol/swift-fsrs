# swift-fsrs

A Swift port of [ts-fsrs](https://github.com/open-spaced-repetition/ts-fsrs) — the canonical TypeScript implementation of the FSRS v6 spaced-repetition algorithm. Pure Swift, zero runtime dependencies, single library product.

## Source of Truth

**ts-fsrs is canonical.** When in doubt, the TypeScript reference at `/tmp/ts-fsrs-audit/packages/fsrs/src/` (or upstream HEAD) wins. If the docs and ts-fsrs disagree, ts-fsrs wins. If a Swift idiom would let us write something cleaner but break numerical parity, we keep the parity and document the awkwardness.

If the reference clone is missing:

```bash
git clone --depth 1 https://github.com/open-spaced-repetition/ts-fsrs.git /tmp/ts-fsrs-audit
```

## Stack

- Swift 6.2 (`swift-tools-version: 6.3`, language mode v6 — strict concurrency on)
- swift-testing (the new framework, not XCTest). All tests live under `Tests/FSRSTests/`.
- No external dependencies. No SPM packages, no system frameworks beyond `Foundation`.
- Single library product `FSRS`.

## Commands

```bash
swift build                                  # debug build (must be 0 warnings)
swift build -c release                       # release build
swift test                                   # full suite — must be 133/133
swift test --filter "FSRS — Rollback"        # run a single suite
swift test --filter "ts-fsrs parity"         # run the byte-parity canary suite
```

## Architecture

```
Sources/FSRS/
|-- FSRS.swift                  # public entry point: schedule, retrievability, rollback, forget
|-- Algorithm.swift             # FSRSAlgorithm: forgetting curve, S/D updates, interval calc
|-- Alea.swift                  # byte-for-byte port of the JS Alea PRNG (used by fuzz)
|-- IntervalFuzzer.swift        # seeded interval-jitter helper
|-- BasicScheduler.swift        # struct: learning-step scheduler (default mode)
|-- LongTermScheduler.swift     # struct: FSRS-only scheduler (no learning steps)
+-- Models/
    |-- Card.swift              # the per-card state (value type, Codable)
    |-- CardState.swift         # .new / .learning / .review / .relearning
    |-- Rating.swift            # .again / .hard / .good / .easy
    |-- Parameters.swift        # 21 weights + scheduler config
    |-- ReviewLog.swift         # immutable per-review record + RecordLogItem
    +-- SchedulingResult.swift  # the four-rating preview bundle

Tests/FSRSTests/
|-- FSRSTests.swift             # the bulk: parity, schedulers, models, integration, rollback, forget
|-- AleaTests.swift             # 5 reference vectors locking the PRNG byte-exact
+-- FuzzParityTests.swift       # 3 determinism tests for the fuzz seed wiring
```

### Concurrency

Strict concurrency is on (Swift 6 language mode). Everything is `Sendable`:

- `FSRS`, `FSRSAlgorithm`, `BasicScheduler`, `LongTermScheduler` — `Sendable struct` (immutable after init)
- `IntervalFuzzer` — `enum` namespace, static methods only
- `Alea` — `struct` with mutable internal RNG state, used briefly inside fuzz, never shared across threads
- All `Models/*` — value types, `Sendable`, most are `Codable + Equatable`

No actors. No locks. No mutable shared state.

## Critical Rules

These are not refactor targets. Don't change them without proving the change is correct against ts-fsrs *and* the existing tests.

### Algorithm formulas are settled
`Sources/FSRS/Algorithm.swift` matches ts-fsrs `algorithm.ts` numerically. Specifically:

- 11 `roundTo(_, decimals: 8)` call sites, each at the position ts-fsrs's `round()` is called. List: `factor` and `intervalModifier` (init), `forgettingCurve` return, `rawInitialDifficulty` return, `nextDifficulty` (linearDamping + reverted intermediates), `nextRecallStability`, `nextForgetStability`, `nextShortTermStability`, `nextState` lapse branch.
- `roundTo` uses `.toNearestOrAwayFromZero` — equivalent to JS `Math.round` for non-negative values (FSRS values always satisfy this). Do NOT change the rounding mode without re-reading `/tmp/ts-fsrs-audit/packages/fsrs/src/help.ts` `round()`.
- If you think a formula is wrong, grep ts-fsrs's `algorithm.ts` and prove the divergence numerically before touching anything. The Sequence A canary (see Testing) must remain exact-equal after any change.

### Default weights are locked
`Parameters.default[0] = 0.212` (NOT 0.2172 — that was a port bug fixed in Wave 1). Asserted by a test at the top of the `ts-fsrs parity` suite. Don't "round" it.

### Alea PRNG is byte-exact
`Sources/FSRS/Alea.swift` is a faithful port of the JS Alea implementation. The JS idioms (`>>> 0`, `| 0`) are intentionally reproduced via `UInt32(truncatingIfNeeded:)` / `Int32(truncatingIfNeeded:)`. Don't "modernize" it. The 5 reference vectors in `AleaTests.swift` lock it byte-exact and will catch any regression.

### Fuzz seed wiring matches ts-fsrs
Both schedulers build the fuzz seed as `"\(time_ms)_\(reps+1)_\(D*S)"` via a private `fuzzSeed(card:now:)` helper. The `+1` matches ts-fsrs `AbstractScheduler.init()`'s pre-bump of `reps` before seed construction. The 3 determinism tests in `FuzzParityTests.swift` lock this in. `IntervalFuzzer.fuzz(..., seed:)` is the only public fuzz API — no back-compat overload.

### Card.scheduledDays is a stored field
`Card.scheduledDays: Int` is a stored property (was a computed one before Wave 4). Set at every scheduler call site that sets `card.due`:

- FSRS-interval path → the algorithm's `interval` value
- ≥1-day learning step → `Int((duration / 86400).rounded(.down))`
- in-day step → 0
- new card → 0

Matches ts-fsrs `basic_scheduler.ts:82/98/105` and `long_term_scheduler.ts:117-126`. `Card.init(from:)` handles legacy JSON without `scheduledDays` via `decodeIfPresent` + the formula `max(0, Int((due - lastReview) / 86400))`.

### Sequence A canary
`Tests/FSRSTests/FSRSTests.swift` "ts-fsrs parity" suite uses exact `==` (no tolerance) for every reference value computed against ts-fsrs. The headline canary: after sequence A step 2,

```
card.stability == 10.96433194    // exact
card.difficulty == 2.11121424    // exact
```

If exact equality breaks, something broke either the algorithm or a round site. **Never relax assertions to make Swift pass — fix Swift.**

## ReviewLog Semantics — Divergence from ts-fsrs

This trips people up, so call it out explicitly. ts-fsrs's `buildLog` (`abstract_scheduler.ts`) populates the log with a *mix* of pre- and post-review values:

| Field          | ts-fsrs source                  | Swift source              |
|----------------|----------------------------------|---------------------------|
| `state`        | `this.current.state` (post)      | `card.state` (pre)        |
| `stability`    | `this.current.stability` (post)  | `card.stability` (pre)    |
| `difficulty`   | `this.current.difficulty` (post) | `card.difficulty` (pre)   |
| `scheduledDays`| `this.current.scheduled_days` (post) | `card.scheduledDays` (pre) |
| `elapsedDays`  | new (computed)                   | new (computed) — match    |

**Swift's logs use pre-review semantics for state/S/D/scheduledDays.** This is locked in by the `Log captures pre-review state` test. It's more useful for `rollback` (we restore directly from the log) and is the simpler mental model. The trade-off: Swift logs aren't byte-compatible with ts-fsrs logs if you wanted to feed them into the ts-fsrs optimizer.

To support `rollback`, `ReviewLog` carries three explicit pre-review snapshot fields (`previousDue`, `previousLastReview`, `previousStep`) instead of overloading `due` like ts-fsrs does. See doc comments in `Models/ReviewLog.swift`.

## Public API Surface

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

`rollback` and `forget` match `ts-fsrs:fsrs.ts`. Notable:

- `rollback`'s lapse decrement only fires for `log.state == .review && log.rating == .again`. Matches ts-fsrs verbatim. In long-term mode, `LongTermScheduler` increments lapses for Again on Learning/Relearning too — those rollbacks won't decrement here. Documented divergence, not a bug.
- `forget` tags its log with `Rating.again` as a stand-in for ts-fsrs's `Rating.Manual` (which Swift deliberately does not have — see "Rating.manual" below). The forget log is **not** safe input to `rollback`. Treat it as audit-only.

## Deliberate Non-Features

### Rating.manual
ts-fsrs has a fifth `Rating.Manual = 0` value, used to tag `forget` and `reschedule` log entries. Swift deliberately omits it because:

1. It's invasive — every exhaustive `switch` on `Rating` would need a `.manual` case (or `fatalError`), and `Rating.allCases` would have to be filtered in scheduler loops.
2. It provides no user-visible behavior — its only purpose is to tag log entries.
3. Scheduling byte-parity with ts-fsrs doesn't depend on it.

If you ever need it (e.g., implementing `reschedule` faithfully), see prior session notes for the full impact analysis.

### reschedule
ts-fsrs's `reschedule` replays a card's full review history under (potentially new) weights, used after retraining the FSRS optimizer. Swift doesn't implement it because (a) Swift has no per-card history persistence — that's the consumer's job, and (b) the design needs a contract (caller passes `[ReviewLog]` vs. adding `Card.history: [ReviewLog]`). Build it only when there's a concrete consumer with an optimizer pipeline.

## Testing

- `swift test` — currently 133 tests across 29 suites, all passing, all under 0.01 s.
- The "ts-fsrs parity" suite is the regression net for numerical parity. It uses exact `==` against ts-fsrs reference values. Do not weaken it.
- `AleaTests` locks the PRNG byte-exact via 5 reference vectors. Do not weaken.
- `FuzzParityTests` locks the seed-wiring determinism via 3 tests. Do not weaken.
- Two Codable round-trip tests (in the "Card.scheduledDays" suite) lock the legacy-JSON migration for cards persisted before `scheduledDays` was a stored field.
- New tests use the `refDate` helper (a fixed `Date(timeIntervalSinceReferenceDate: 800_000_000)`) for determinism. Don't introduce `Date()` into tests.

### Verification gates after any change
1. `swift build 2>&1 | tail -5` — zero errors, zero warnings.
2. `swift test 2>&1 | tail -5` — count strictly grows, all pass.
3. Sequence A canary: `card.stability == 10.96433194` and `card.difficulty == 2.11121424` exactly at step 2 (auto-checked by the parity suite).
4. If touching schedulers: confirm `hardDue == refDate + 360s` for a new-card Hard with default `learningSteps = [60, 600]` (auto-checked).
5. If touching fuzz: re-run `AleaTests` and `FuzzParityTests` (auto-checked).
6. If touching `Card.init(from:)`: re-run the Codable backward-compat tests (auto-checked).

## Cross-Checking Numerically Against ts-fsrs

There's a small Python ts-fsrs port at `/tmp/fsrs_ref.py` (re-create from `/tmp/ts-fsrs-audit/packages/fsrs/src/algorithm.ts` if missing) for ad-hoc cross-checks. When chasing a parity bug, the workflow is:

1. Find the smallest scenario that diverges (a single `nextDifficulty(d, .good)` call, etc.).
2. Run it through the Python reference to get the canonical value.
3. Run it through Swift.
4. If they disagree past the 8th decimal, look for a missing or extra `roundTo` site, or a sign / order-of-operations mismatch.

## Gotchas

- **Swift 6 strict concurrency** is on by default — every new type that crosses an actor or scheduling boundary must be `Sendable`.
- **Default learning steps are `[60, 600]`** (in seconds). A new-card Hard fires at +360s, not +60s and not +600s — `BasicScheduler`'s `hardIntervalMinutes(steps:)` helper is step-independent. See `BasicScheduler.swift:200`-ish.
- **Long-step learning graduation** (`steps[i] >= 86400`) uses the raw minute duration for the due date, not a rounded day count. Locked in by Wave 2 fixes.
- **`LongTermScheduler` strict ordering**: again < hard < good < easy. The min/max chain in `scheduleReview` enforces this — don't reorder.
- **`Card.elapsedDays(now:)` floors to UTC midnight** to match ts-fsrs `dateDiffInDays`. So a review at 23:00 UTC followed by one at 01:00 UTC the next day returns 1, not 0. Don't switch to a seconds-based difference.
- **`card.scheduledDays` is set at every `due` write** in the schedulers — if you add a new `card.due = ...` site, you must also set `card.scheduledDays`.
- **`Weights.init(array:)` rejects NaN/Inf**. Optimizer output sometimes contains them; the rejection is intentional, not a bug to fix.
