import Foundation
import Testing

@testable import FSRS

// MARK: - ts-fsrs parity for rollback / forget
//
// This file ports the two ts-fsrs reference suites:
//   - /tmp/ts-fsrs-audit/packages/fsrs/__tests__/rollback.test.ts
//   - /tmp/ts-fsrs-audit/packages/fsrs/__tests__/forget.test.ts
//
// The ts-fsrs tests are *behavioural identity* tests: they don't hardcode
// post-rollback / post-forget S/D/due numerics, they assert structural
// equality against the original card (rollback) or against a spread-built
// expected card (forget). We mirror that here, but extend coverage to every
// pre-review state (`.new`, `.learning`, `.review`, `.relearning`) and all
// four ratings — ts-fsrs only covers `.new` and `.review` directly.
//
// All assertions use exact `==` on Card. No tolerance.
//
// Documented divergences (per CLAUDE.md, NOT enforced by these tests):
//   1. Swift's ReviewLog stores pre-review S/D/state/scheduledDays;
//      ts-fsrs stores post-review. We deliberately don't compare log fields.
//   2. Swift's `forget` log uses Rating.again as a stand-in for ts-fsrs's
//      Rating.Manual (Swift omits Manual). We don't assert on log.rating.
//   3. Swift's `rollback` only decrements lapses on
//      log.state == .review && rating == .again — matches ts-fsrs verbatim
//      including its long-term-mode under-decrement quirk.

/// The exact reference dates used by ts-fsrs's rollback/forget tests.
///
/// JS `new Date(2022, 11, 29, 12, 30, 0, 0)` is locale-dependent (month is
/// 0-indexed → December 29). We pin the UTC equivalent here for determinism.
/// The exact choice doesn't affect the round-trip identity tests — what
/// matters is that the same date threads through schedule and rollback.
private let tsRefDate1: Date = Date(timeIntervalSince1970: 1_672_317_000)  // 2022-12-29 12:30 UTC
private let tsRefDate2: Date = Date(timeIntervalSince1970: 1_703_939_400)  // 2023-12-30 12:30 UTC

/// Builds the FSRS instance ts-fsrs uses for these two suites: the 17-weight
/// (FSRS-5) array, no fuzz, with ts-fsrs's documented 17→21 migration applied.
///
/// ts-fsrs migrates 17-weight inputs via `migrateParameters` in `default.ts`:
/// - w[4] = (w[5] * 2 + w[4]).toFixed(8)
/// - w[5] = (ln(w[5] * 3 + 1) / 3).toFixed(8)
/// - w[6] = (w[6] + 0.5).toFixed(8)
/// - append [0.0, 0.0, 0.0, FSRS5_DEFAULT_DECAY (=0.5)]
///
/// We compute the migrated values explicitly — this lets the test exercise
/// the same effective weights ts-fsrs uses, even though the round-trip
/// identity assertions don't actually depend on the weight values.
///
/// Note: w[19] is fed in as 0.0 from the migration, but Swift's
/// `applyContextDependentWeightRanges` clamps to ≥ 0.01 when
/// `enableShortTerm == true` (matching ts-fsrs's `CLAMP_PARAMETERS`).
private func tsParityFSRS(enableShortTerm: Bool = true) -> FSRS {
    // Source: 17-weight array from ts-fsrs rollback.test.ts / forget.test.ts.
    let inputs: [Double] = [
        1.14, 1.01, 5.44, 14.67,
        5.3024, 1.5662, 1.2503, 0.0028,
        1.5489, 0.1763, 0.9953,
        2.7473, 0.0179, 0.3105, 0.3976,
        0.0, 2.0902,
    ]
    // Apply ts-fsrs's 17→21 migration formulas (toFixed(8) precision).
    let migrated_w4 = ((inputs[5] * 2.0 + inputs[4]) * 1e8).rounded() / 1e8
    let migrated_w5 = (log(inputs[5] * 3.0 + 1.0) / 3.0 * 1e8).rounded() / 1e8
    let migrated_w6 = ((inputs[6] + 0.5) * 1e8).rounded() / 1e8
    let migrated: [Double] = [
        inputs[0], inputs[1], inputs[2], inputs[3],
        migrated_w4, migrated_w5, migrated_w6, inputs[7],
        inputs[8], inputs[9], inputs[10],
        inputs[11], inputs[12], inputs[13], inputs[14],
        inputs[15], inputs[16],
        0.0, 0.0, 0.0, 0.5,  // FSRS5_DEFAULT_DECAY = 0.5
    ]
    let weights = Weights(array: migrated)
    let params = Parameters(
        weights: weights,
        enableFuzz: false,
        enableShortTerm: enableShortTerm
    )
    return FSRS(parameters: params)
}

// MARK: - Helpers

/// Drives a card to the given state for use as a rollback / forget input.
///
/// Returns the card immediately after entering `targetState` for the first
/// time so subsequent `schedule(...)` calls produce a single-step round trip
/// that we can test rollback against.
private func driveToState(
    _ targetState: CardState,
    using fsrs: FSRS,
    startingAt now: Date = tsRefDate1
) -> Card {
    var card = FSRS.createCard(now: now)
    switch targetState {
    case .new:
        return card
    case .learning:
        // First Good on a new card with default learning steps lands at step 1
        // in the .learning state.
        card = fsrs.schedule(card: card, now: now, rating: .good).card
        precondition(card.state == .learning)
        return card
    case .review:
        // Easy from new graduates straight to .review.
        card = fsrs.schedule(card: card, now: now, rating: .easy).card
        precondition(card.state == .review)
        return card
    case .relearning:
        // Easy → Review, then Again → Relearning.
        card = fsrs.schedule(card: card, now: now, rating: .easy).card
        card = fsrs.schedule(card: card, now: card.due, rating: .again).card
        precondition(card.state == .relearning)
        return card
    }
}

// MARK: - Rollback parity (ports rollback.test.ts)

@Suite("ts-fsrs parity — rollback")
struct RollbackParityTests {

    // MARK: it('first rollback') — ts-fsrs rollback.test.ts:17-29

    /// ts-fsrs rollback.test.ts:17-29 — round-trip from `.new` across all four
    /// ratings. Asserts `f.rollback(scheduling_cards[r].card, log) == card`.
    @Test("Rollback from .new round-trips for every rating (rollback.test.ts:17-29)")
    func rollbackFromNew_allRatings() {
        let fsrs = tsParityFSRS()
        let card = FSRS.createCard(now: tsRefDate1)
        let preview = fsrs.schedule(card: card, now: tsRefDate1)

        for item in [preview.again, preview.hard, preview.good, preview.easy] {
            let rolled = fsrs.rollback(card: item.card, log: item.log)
            #expect(rolled == card,
                    "rollback from .new + \(item.log.rating) did not restore the original card")
        }
    }

    // MARK: it('rollback 2') — ts-fsrs rollback.test.ts:31-46

    /// ts-fsrs rollback.test.ts:31-46 — round-trip from `.review` (after one
    /// Easy) across all four ratings.
    @Test("Rollback from .review round-trips for every rating (rollback.test.ts:31-46)")
    func rollbackFromReview_allRatings() {
        let fsrs = tsParityFSRS()
        var card = FSRS.createCard(now: tsRefDate1)
        card = fsrs.schedule(card: card, now: tsRefDate1, rating: .easy).card
        precondition(card.state == .review)
        let snapshot = card

        let preview = fsrs.schedule(card: card, now: card.due)
        for item in [preview.again, preview.hard, preview.good, preview.easy] {
            let rolled = fsrs.rollback(card: item.card, log: item.log)
            #expect(rolled == snapshot,
                    "rollback from .review + \(item.log.rating) did not restore the original card")
        }
    }

    // MARK: Extension — coverage that ts-fsrs doesn't directly exercise

    /// Round-trip from `.learning`, every rating. ts-fsrs only tests `.new`
    /// and `.review`; this fills the gap so any divergence in Swift's
    /// learning-state restoration would surface here.
    @Test("Rollback from .learning round-trips for every rating")
    func rollbackFromLearning_allRatings() {
        let fsrs = tsParityFSRS()
        let learning = driveToState(.learning, using: fsrs)
        let snapshot = learning

        let preview = fsrs.schedule(card: learning, now: learning.due)
        for item in [preview.again, preview.hard, preview.good, preview.easy] {
            let rolled = fsrs.rollback(card: item.card, log: item.log)
            #expect(rolled == snapshot,
                    "rollback from .learning + \(item.log.rating) did not restore the original card")
        }
    }

    /// Round-trip from `.relearning`, every rating.
    @Test("Rollback from .relearning round-trips for every rating")
    func rollbackFromRelearning_allRatings() {
        let fsrs = tsParityFSRS()
        let relearning = driveToState(.relearning, using: fsrs)
        let snapshot = relearning

        let preview = fsrs.schedule(card: relearning, now: relearning.due)
        for item in [preview.again, preview.hard, preview.good, preview.easy] {
            let rolled = fsrs.rollback(card: item.card, log: item.log)
            #expect(rolled == snapshot,
                    "rollback from .relearning + \(item.log.rating) did not restore the original card")
        }
    }

    // MARK: Field-level checks on the round-trip target

    /// Verifies the per-field semantics of `rollback` on a `.review` card:
    /// due, lastReview, stability, difficulty, state, step, scheduledDays,
    /// reps, lapses all individually match the pre-review snapshot. This
    /// catches a regression where round-trip equality holds by coincidence
    /// (e.g., two compensating bugs in due/lastReview restoration).
    @Test("Rollback restores all card fields individually (.review starting state)")
    func rollbackRestoresAllFieldsFromReview() {
        let fsrs = tsParityFSRS()
        var card = FSRS.createCard(now: tsRefDate1)
        card = fsrs.schedule(card: card, now: tsRefDate1, rating: .easy).card
        let snapshot = card

        for rating in Rating.allCases {
            let result = fsrs.schedule(card: card, now: card.due, rating: rating)
            let rolled = fsrs.rollback(card: result.card, log: result.log)

            #expect(rolled.due == snapshot.due, "due mismatch on \(rating)")
            #expect(rolled.lastReview == snapshot.lastReview, "lastReview mismatch on \(rating)")
            #expect(rolled.stability == snapshot.stability, "stability mismatch on \(rating)")
            #expect(rolled.difficulty == snapshot.difficulty, "difficulty mismatch on \(rating)")
            #expect(rolled.state == snapshot.state, "state mismatch on \(rating)")
            #expect(rolled.step == snapshot.step, "step mismatch on \(rating)")
            #expect(rolled.scheduledDays == snapshot.scheduledDays, "scheduledDays mismatch on \(rating)")
            #expect(rolled.reps == snapshot.reps, "reps mismatch on \(rating)")
            #expect(rolled.lapses == snapshot.lapses, "lapses mismatch on \(rating)")
        }
    }

    /// Verifies rollback from `.new` restores `lastReview = nil` (since the
    /// original card had no review history) and `due` to the original due
    /// (not the review time). Matches ts-fsrs's `case State.New` branch in
    /// `fsrs.ts:rollback`.
    @Test("Rollback from .new restores lastReview=nil and original due")
    func rollbackFromNew_restoresOriginalTimeline() {
        let fsrs = tsParityFSRS()
        let card = FSRS.createCard(now: tsRefDate1)

        for rating in Rating.allCases {
            let result = fsrs.schedule(card: card, now: tsRefDate1, rating: rating)
            let rolled = fsrs.rollback(card: result.card, log: result.log)

            #expect(rolled.lastReview == nil,
                    "rollback from .new on \(rating) should null out lastReview")
            #expect(rolled.due == card.due,
                    "rollback from .new on \(rating) should restore original due")
            #expect(rolled.lapses == 0,
                    "rollback from .new on \(rating) should zero lapses")
        }
    }
}

// MARK: - Forget parity (ports forget.test.ts)

@Suite("ts-fsrs parity — forget")
struct ForgetParityTests {

    // MARK: it('forget') — resetCount=true loop, ts-fsrs forget.test.ts:17-45

    /// ts-fsrs forget.test.ts:17-45 (first loop, reset_count=true).
    ///
    /// ts-fsrs asserts:
    /// ```
    /// expect(forgetCard.card).toEqual({
    ///   ...card,                   // empty card defaults
    ///   due: forget_now,
    ///   lapses: 0,
    ///   reps: 0,
    ///   last_review: scheduling_cards[grade].card.last_review,  // POST-review value
    /// })
    /// ```
    /// We exercise every rating and check each derived field against the
    /// expected ts-fsrs result.
    @Test("Forget(reset=true) on a post-review card matches ts-fsrs (forget.test.ts:17-45)")
    func forget_resetTrue_allRatings() {
        let fsrs = tsParityFSRS()
        let original = FSRS.createCard(now: tsRefDate1)
        let preview = fsrs.schedule(card: original, now: tsRefDate1)

        for item in [preview.again, preview.hard, preview.good, preview.easy] {
            let postReview = item.card
            let forgotten = fsrs.forget(card: postReview, now: tsRefDate2, resetCount: true).card

            // Expected: spread of the original empty card with these overrides.
            #expect(forgotten.due == tsRefDate2, "due mismatch on \(item.log.rating)")
            #expect(forgotten.lapses == 0, "lapses mismatch on \(item.log.rating)")
            #expect(forgotten.reps == 0, "reps mismatch on \(item.log.rating)")
            #expect(forgotten.lastReview == postReview.lastReview,
                    "lastReview should be preserved from post-review state on \(item.log.rating)")

            // Spread of `card` (createEmptyCard defaults) — these come through.
            #expect(forgotten.stability == 0, "stability mismatch on \(item.log.rating)")
            #expect(forgotten.difficulty == 0, "difficulty mismatch on \(item.log.rating)")
            #expect(forgotten.scheduledDays == 0, "scheduledDays mismatch on \(item.log.rating)")
            #expect(forgotten.step == 0, "step mismatch on \(item.log.rating)")
            #expect(forgotten.state == .new, "state mismatch on \(item.log.rating)")
        }
    }

    // MARK: it('forget') — resetCount=false loop, ts-fsrs forget.test.ts:46-59

    /// ts-fsrs forget.test.ts:46-59 (second loop, reset_count omitted = false).
    ///
    /// ts-fsrs asserts:
    /// ```
    /// expect(forgetCard.card).toEqual({
    ///   ...card,
    ///   due: forget_now,
    ///   lapses: scheduling_cards[grade].card.lapses,
    ///   reps:   scheduling_cards[grade].card.reps,
    ///   last_review: scheduling_cards[grade].card.last_review,
    /// })
    /// ```
    @Test("Forget(reset=false) on a post-review card matches ts-fsrs (forget.test.ts:46-59)")
    func forget_resetFalse_allRatings() {
        let fsrs = tsParityFSRS()
        let original = FSRS.createCard(now: tsRefDate1)
        let preview = fsrs.schedule(card: original, now: tsRefDate1)

        for item in [preview.again, preview.hard, preview.good, preview.easy] {
            let postReview = item.card
            let forgotten = fsrs.forget(card: postReview, now: tsRefDate2, resetCount: false).card

            #expect(forgotten.due == tsRefDate2, "due mismatch on \(item.log.rating)")
            #expect(forgotten.lapses == postReview.lapses,
                    "lapses should be preserved on \(item.log.rating)")
            #expect(forgotten.reps == postReview.reps,
                    "reps should be preserved on \(item.log.rating)")
            #expect(forgotten.lastReview == postReview.lastReview,
                    "lastReview should be preserved on \(item.log.rating)")

            #expect(forgotten.stability == 0, "stability mismatch on \(item.log.rating)")
            #expect(forgotten.difficulty == 0, "difficulty mismatch on \(item.log.rating)")
            #expect(forgotten.scheduledDays == 0, "scheduledDays mismatch on \(item.log.rating)")
            #expect(forgotten.step == 0, "step mismatch on \(item.log.rating)")
            #expect(forgotten.state == .new, "state mismatch on \(item.log.rating)")
        }
    }

    // MARK: it('new card forget[reset true]') — ts-fsrs forget.test.ts:62-72

    /// ts-fsrs forget.test.ts:62-72 — forget a brand-new (never-reviewed) card
    /// with reset_count=true. Expected: `{...card, due: forget_now, lapses: 0,
    /// reps: 0}`. Note `last_review` is NOT in the override list, so the
    /// expected value is `undefined` (the spread default from createEmptyCard).
    @Test("Forget(reset=true) on a new card matches ts-fsrs (forget.test.ts:62-72)")
    func forget_resetTrue_onNewCard() {
        let fsrs = tsParityFSRS()
        let card = FSRS.createCard(now: tsRefDate1)
        let forgotten = fsrs.forget(card: card, now: tsRefDate2, resetCount: true).card

        #expect(forgotten.due == tsRefDate2)
        #expect(forgotten.lapses == 0)
        #expect(forgotten.reps == 0)
        #expect(forgotten.lastReview == nil)  // never-reviewed: stays nil
        #expect(forgotten.stability == 0)
        #expect(forgotten.difficulty == 0)
        #expect(forgotten.scheduledDays == 0)
        #expect(forgotten.step == 0)
        #expect(forgotten.state == .new)
    }

    // MARK: it('new card forget[reset true]') — second occurrence, ts-fsrs forget.test.ts:73-81
    // (Note: the test name is mis-copied in upstream; this one is reset=false.)

    /// ts-fsrs forget.test.ts:73-81 — forget a brand-new card with
    /// reset_count omitted (i.e., false). Expected: `{...card, due:
    /// forget_now}` — every other field stays at the createEmptyCard default
    /// (which already has reps=0, lapses=0, last_review=undefined for a new
    /// card, so the resetCount distinction is invisible here).
    @Test("Forget(reset=false) on a new card matches ts-fsrs (forget.test.ts:73-81)")
    func forget_resetFalse_onNewCard() {
        let fsrs = tsParityFSRS()
        let card = FSRS.createCard(now: tsRefDate1)
        let forgotten = fsrs.forget(card: card, now: tsRefDate2).card

        #expect(forgotten.due == tsRefDate2)
        #expect(forgotten.lapses == 0)  // was already 0
        #expect(forgotten.reps == 0)    // was already 0
        #expect(forgotten.lastReview == nil)
        #expect(forgotten.stability == 0)
        #expect(forgotten.difficulty == 0)
        #expect(forgotten.scheduledDays == 0)
        #expect(forgotten.step == 0)
        #expect(forgotten.state == .new)
    }

    // MARK: Extension — coverage for .learning and .relearning starting states

    /// Forget(reset=true) starting from `.learning`. ts-fsrs's test only
    /// covers .new (post-Easy goes to .review). This case checks that we
    /// preserve `lastReview` even for a card that's mid-learning.
    @Test("Forget(reset=true) on a .learning card preserves lastReview, zeros counters")
    func forget_resetTrue_fromLearning() {
        let fsrs = tsParityFSRS()
        let learning = driveToState(.learning, using: fsrs)
        let lastReviewBefore = learning.lastReview
        // A card in .learning state must have a lastReview (the time of the
        // initial Good); guard the precondition explicitly.
        #expect(lastReviewBefore != nil)

        let forgotten = fsrs.forget(card: learning, now: tsRefDate2, resetCount: true).card

        #expect(forgotten.due == tsRefDate2)
        #expect(forgotten.lapses == 0)
        #expect(forgotten.reps == 0)
        #expect(forgotten.lastReview == lastReviewBefore)
        #expect(forgotten.stability == 0)
        #expect(forgotten.difficulty == 0)
        #expect(forgotten.scheduledDays == 0)
        #expect(forgotten.step == 0)
        #expect(forgotten.state == .new)
    }

    /// Forget(reset=false) starting from `.learning` — counters preserved.
    @Test("Forget(reset=false) on a .learning card preserves lastReview, reps, lapses")
    func forget_resetFalse_fromLearning() {
        let fsrs = tsParityFSRS()
        let learning = driveToState(.learning, using: fsrs)

        let forgotten = fsrs.forget(card: learning, now: tsRefDate2, resetCount: false).card

        #expect(forgotten.reps == learning.reps)
        #expect(forgotten.lapses == learning.lapses)
        #expect(forgotten.lastReview == learning.lastReview)
        #expect(forgotten.due == tsRefDate2)
        #expect(forgotten.stability == 0)
        #expect(forgotten.difficulty == 0)
        #expect(forgotten.state == .new)
        #expect(forgotten.scheduledDays == 0)
        #expect(forgotten.step == 0)
    }

    /// Forget(reset=true) starting from `.relearning`. Locks in the lastReview
    /// preservation invariant for a card whose most recent review was a lapse.
    @Test("Forget(reset=true) on a .relearning card preserves lastReview, zeros counters")
    func forget_resetTrue_fromRelearning() {
        let fsrs = tsParityFSRS()
        let relearning = driveToState(.relearning, using: fsrs)
        let lastReviewBefore = relearning.lastReview
        #expect(lastReviewBefore != nil)

        let forgotten = fsrs.forget(card: relearning, now: tsRefDate2, resetCount: true).card

        #expect(forgotten.lastReview == lastReviewBefore)
        #expect(forgotten.due == tsRefDate2)
        #expect(forgotten.lapses == 0)
        #expect(forgotten.reps == 0)
        #expect(forgotten.stability == 0)
        #expect(forgotten.difficulty == 0)
        #expect(forgotten.state == .new)
        #expect(forgotten.scheduledDays == 0)
        #expect(forgotten.step == 0)
    }

    /// Forget(reset=false) starting from `.relearning`.
    @Test("Forget(reset=false) on a .relearning card preserves lastReview, reps, lapses")
    func forget_resetFalse_fromRelearning() {
        let fsrs = tsParityFSRS()
        let relearning = driveToState(.relearning, using: fsrs)

        let forgotten = fsrs.forget(card: relearning, now: tsRefDate2, resetCount: false).card

        #expect(forgotten.reps == relearning.reps)
        #expect(forgotten.lapses == relearning.lapses)
        #expect(forgotten.lastReview == relearning.lastReview)
        #expect(forgotten.due == tsRefDate2)
        #expect(forgotten.stability == 0)
        #expect(forgotten.difficulty == 0)
        #expect(forgotten.state == .new)
        #expect(forgotten.scheduledDays == 0)
        #expect(forgotten.step == 0)
    }

    // MARK: lastReview semantics — the rollback/forget asymmetry

    /// `forget` PRESERVES `lastReview` (matches ts-fsrs verbatim — see the
    /// `last_review: processedCard.last_review` line in `fsrs.ts:forget`).
    /// `rollback`, in contrast, RESTORES `lastReview` from the pre-review
    /// snapshot held in the log (`previousLastReview`). This test pins the
    /// asymmetry: starting from the same review event, forget yields a
    /// different `lastReview` than rollback.
    @Test("Forget preserves lastReview; rollback restores previousLastReview")
    func lastReviewAsymmetry_forgetVsRollback() {
        let fsrs = tsParityFSRS()
        var card = FSRS.createCard(now: tsRefDate1)
        // Drive to .review so there's a meaningful pre-review lastReview to
        // compare against (will be nil — first review — but still distinct
        // from the post-review value).
        let preReview = card
        let result = fsrs.schedule(card: card, now: tsRefDate1, rating: .easy)
        card = result.card

        let forgotten = fsrs.forget(card: card, now: tsRefDate2).card
        let rolled = fsrs.rollback(card: card, log: result.log)

        // forget: lastReview is what the card had AFTER the review (set by scheduler)
        #expect(forgotten.lastReview == card.lastReview)

        // rollback: lastReview is what the card had BEFORE the review (nil for new cards)
        #expect(rolled.lastReview == preReview.lastReview)
        #expect(rolled.lastReview == nil)

        // And they're different (post-review lastReview is non-nil after first review).
        #expect(forgotten.lastReview != rolled.lastReview)
    }
}
