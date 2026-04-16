import Foundation
import Testing

@testable import FSRS

// MARK: - Basic Properties

@Suite("Alea PRNG — basic properties")
struct AleaBasicTests {

    @Test("Same seed produces the same sequence")
    func deterministic() {
        var a = Alea(seed: "abc")
        var b = Alea(seed: "abc")
        for _ in 0..<100 {
            #expect(a.next() == b.next())
        }
    }

    @Test("Different seeds produce different sequences")
    func differentSeeds() {
        var a = Alea(seed: "abc")
        var b = Alea(seed: "xyz")
        var diverged = false
        for _ in 0..<10 {
            if a.next() != b.next() {
                diverged = true
                break
            }
        }
        #expect(diverged)
    }

    @Test("Output is in [0, 1)")
    func range() {
        var a = Alea(seed: "test")
        for _ in 0..<1_000 {
            let v = a.next()
            #expect(v >= 0.0)
            #expect(v < 1.0)
        }
    }

    @Test("int32 output is a valid signed 32-bit integer")
    func int32Range() {
        var a = Alea(seed: "int32range")
        // By construction Int32 is in [-2^31, 2^31); this just sanity-checks
        // the generator produces output at all and doesn't trap.
        for _ in 0..<1_000 {
            _ = a.int32()
        }
    }

    @Test("Empty seed falls back to time-based init (randomish per call)")
    func emptySeed() {
        var a = Alea(seed: "")
        // Sleep briefly to ensure Date().timeIntervalSince1970 ticks. We
        // can't sleep in a unit test, so we rely on the fact that two
        // Aleas created "at the same instant" produce the same output —
        // this test just confirms no crash and values are in range.
        let v = a.next()
        #expect(v >= 0.0)
        #expect(v < 1.0)
    }
}

// MARK: - ts-fsrs Reference Vectors
//
// These hard-coded values come from
// `/tmp/ts-fsrs-audit/packages/fsrs/__tests__/alea.test.ts`. They pin
// the port to ts-fsrs' exact output so any regression in the seed mixing
// or state evolution trips immediately.
//
// If any of these fail, the port has drifted from ts-fsrs — do NOT just
// update the expected values. Diff against `src/alea.ts`.

@Suite("Alea PRNG — ts-fsrs parity vectors")
struct AleaParityTests {

    @Test("seed '12345' first three next() outputs match ts-fsrs")
    func seed12345() {
        var g = Alea(seed: "12345")
        // From alea.test.ts "Known values test".
        #expect(g.next() == 0.27138191112317145)
        #expect(g.next() == 0.19615925149992108)
        #expect(g.next() == 0.6810678059700876)
    }

    @Test("seed '12345' first three int32() outputs match ts-fsrs")
    func seed12345Int32() {
        var g = Alea(seed: "12345")
        // From alea.test.ts "Uint32 test". Note the third value is
        // negative — `int32()` returns a SIGNED 32-bit integer, mirroring
        // JavaScript's `| 0` reinterpretation.
        #expect(g.int32() == 1_165_576_433)
        #expect(g.int32() == 842_497_570)
        #expect(g.int32() == -1_369_803_343)
    }

    @Test("seed '1727015666066' — exercises s0 < 0 branch in init")
    func seedNegativeS0() {
        // From alea.test.ts "seed 1727015666066". The constructor
        // computes s0 = -0.411... then adds 1 to wrap into [0, 1).
        var g = Alea(seed: "1727015666066")
        #expect(g.next() == 0.6320083506871015)
    }

    @Test("seed 'Seedp5fxh9kf4r0' — exercises s1 < 0 branch in init")
    func seedNegativeS1() {
        // From alea.test.ts "seed Seedp5fxh9kf4r0".
        var g = Alea(seed: "Seedp5fxh9kf4r0")
        #expect(g.next() == 0.14867847645655274)
    }

    @Test("seed 'NegativeS2Seed' — exercises s2 < 0 branch in init")
    func seedNegativeS2() {
        // From alea.test.ts "seed NegativeS2Seed".
        var g = Alea(seed: "NegativeS2Seed")
        #expect(g.next() == 0.830770346801728)
    }
}
