import Testing
import Foundation
@testable import OpenMDictKit

@Suite
struct RemoteDeletePolicyTests {

    static let t0 = Date(timeIntervalSince1970: 1_759_900_000)
    static func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    static let eleven: Set<String> = Set((1...11).map { "dict-\($0)" })

    /// 2026-10-08 iPad mini 4: every metadata row vanished while the
    /// mirroring delegate was resetting. Nothing may be nominated.
    @Test("Incident replay: all rows gone during a reset nominates nothing")
    func incidentReplayHeld() {
        let e = RemoteDeletePolicy.evaluate(
            loadedIds: Self.eleven,
            metadataIds: [],
            previousPending: [:],
            recoverableFromCloud: Self.eleven,
            lastSuccessfulImportEnd: Self.at(-1),
            resetSuspected: true,
            lastVerifiedAfter: [:],
            now: Self.t0
        )
        #expect(e.heldForReset)
        #expect(e.candidates.isEmpty)
        #expect(e.unrecoverable.isEmpty)
        #expect(e.pending.count == 11)
        #expect(e.pending.values.allSatisfy { $0 == Self.t0 })
    }

    @Test("Without the reset latch the rows are only nominated for verification, never deleted outright")
    func incidentReplayWithoutLatch() {
        let e = RemoteDeletePolicy.evaluate(
            loadedIds: Self.eleven,
            metadataIds: [],
            previousPending: [:],
            recoverableFromCloud: Self.eleven,
            lastSuccessfulImportEnd: Self.at(-1),
            resetSuspected: false,
            lastVerifiedAfter: [:],
            now: Self.t0
        )
        #expect(!e.heldForReset)
        #expect(e.candidates == Self.eleven)
        #expect(e.pending.count == 11)
    }

    @Test("Never-uploaded dictionaries are unrecoverable and never candidates")
    func unrecoverableNeverNominated() {
        let e = RemoteDeletePolicy.evaluate(
            loadedIds: ["imported", "kjv"],
            metadataIds: [],
            previousPending: [:],
            recoverableFromCloud: ["kjv"],
            lastSuccessfulImportEnd: Self.at(-1),
            resetSuspected: false,
            lastVerifiedAfter: [:],
            now: Self.t0
        )
        #expect(e.unrecoverable == ["imported"])
        #expect(e.candidates == ["kjv"])
    }

    @Test("No import ever observed: nothing is nominated")
    func noImportNoCandidates() {
        let e = RemoteDeletePolicy.evaluate(
            loadedIds: ["a"],
            metadataIds: [],
            previousPending: [:],
            recoverableFromCloud: ["a"],
            lastSuccessfulImportEnd: nil,
            resetSuspected: false,
            lastVerifiedAfter: [:],
            now: Self.t0
        )
        #expect(e.candidates.isEmpty)
        #expect(e.pending == ["a": Self.t0])
    }

    @Test("A verified candidate is not re-nominated until a newer import completes")
    func verificationIsPerImport() {
        let first = RemoteDeletePolicy.evaluate(
            loadedIds: ["a"], metadataIds: [], previousPending: [:],
            recoverableFromCloud: ["a"], lastSuccessfulImportEnd: Self.at(10),
            resetSuspected: false, lastVerifiedAfter: ["a": Self.at(10)], now: Self.at(20)
        )
        #expect(first.candidates.isEmpty)

        let later = RemoteDeletePolicy.evaluate(
            loadedIds: ["a"], metadataIds: [], previousPending: first.pending,
            recoverableFromCloud: ["a"], lastSuccessfulImportEnd: Self.at(30),
            resetSuspected: false, lastVerifiedAfter: ["a": Self.at(10)], now: Self.at(40)
        )
        #expect(later.candidates == ["a"])
        #expect(later.pending == ["a": Self.at(20)], "first-seen time is preserved across passes")
    }

    @Test("Rows that come back are reported as reappeared and dropped from pending")
    func reappearedRows() {
        let e = RemoteDeletePolicy.evaluate(
            loadedIds: ["a", "b"],
            metadataIds: ["a", "b"],
            previousPending: ["a": Self.at(-5), "b": Self.at(-5)],
            recoverableFromCloud: ["a", "b"],
            lastSuccessfulImportEnd: Self.t0,
            resetSuspected: false,
            lastVerifiedAfter: [:],
            now: Self.t0
        )
        #expect(e.reappeared == ["a", "b"])
        #expect(e.pending.isEmpty)
        #expect(e.candidates.isEmpty)
    }

    @Test("Steady state with nothing missing is a no-op")
    func steadyState() {
        let e = RemoteDeletePolicy.evaluate(
            loadedIds: ["a"], metadataIds: ["a", "b"], previousPending: [:],
            recoverableFromCloud: ["a"], lastSuccessfulImportEnd: Self.t0,
            resetSuspected: false, lastVerifiedAfter: [:], now: Self.t0
        )
        #expect(e == RemoteDeleteEvaluation())
    }

    @Test("A genuine remote delete of one dictionary is nominated while the others stay untouched")
    func singleRemoteDelete() {
        let e = RemoteDeletePolicy.evaluate(
            loadedIds: ["a", "b", "c"], metadataIds: ["a", "c"], previousPending: [:],
            recoverableFromCloud: ["a", "b", "c"], lastSuccessfulImportEnd: Self.t0,
            resetSuspected: false, lastVerifiedAfter: [:], now: Self.t0
        )
        #expect(e.candidates == ["b"])
        #expect(e.pending.keys.sorted() == ["b"])
    }
}
