import XCTest
@testable import LidLidServiceCore
import LidLidServiceProtocol
import Security

private final class Power: SleepSetting {
    var value = false
    var rejectRead = false
    var rejectWrite = false
    var failAfterMutation = false
    var ignoreWrites = false
    var writes: [Bool] = []
    func read() throws -> Bool {
        if rejectRead { throw ServiceFailure("系统睡眠设置超时，请保持开盖并重试") }
        return value
    }
    func write(disabled: Bool) throws {
        if rejectWrite { throw ServiceFailure("test write failure") }
        if !ignoreWrites { value = disabled }; writes.append(disabled)
        if failAfterMutation && disabled { throw ServiceFailure("test partial mutation") }
    }
}
private final class Journal: SleepJournalStore {
    var value: SleepJournal?
    var failSave = false
    var failClear = false
    func load() throws -> SleepJournal? { value }
    func save(_ value: SleepJournal) throws {
        if failSave { throw ServiceFailure("test journal full") }
        self.value = value
    }
    func clear() throws {
        if failClear { throw ServiceFailure("test clear failure") }
        value = nil
    }
}
final class SleepLeaseTests: XCTestCase {
    private func fixture() -> (SleepLease, Power, Journal) {
        let power = Power(), journal = Journal()
        return (SleepLease(power: power, journal: journal), power, journal)
    }
    func testOneShotAndExactRestore() throws {
        let (service, power, journal) = fixture(); let owner = UUID()
        try service.begin(owner: owner, minutes: 0, now: 0, lidClosed: false)
        XCTAssertTrue(power.value); XCTAssertEqual(journal.value?.originalDisabled, false)
        XCTAssertFalse(service.recoveryPending, "A healthy active session must not look like failed recovery")
        try service.tick(now: 1, lidClosed: false, safe: true)
        XCTAssertTrue(service.active)
        try service.tick(now: 2, lidClosed: true, safe: true)
        try service.tick(now: 3, lidClosed: false, safe: true)
        XCTAssertFalse(service.active); XCTAssertFalse(power.value); XCTAssertNil(journal.value)
        XCTAssertThrowsError(try service.renew(owner: owner, now: 4))
    }
    func testLeaseExpiryEvenWithNoLidTransition() throws {
        let (service, power, journal) = fixture(); let owner = UUID()
        try service.begin(owner: owner, minutes: 0, now: 0, lidClosed: false)
        try service.renew(owner: owner, now: 20)
        try service.tick(now: 49, lidClosed: true, safe: true)
        XCTAssertTrue(power.value)
        try service.tick(now: 50, lidClosed: true, safe: true)
        XCTAssertFalse(power.value); XCTAssertNil(journal.value)
    }
    func testWrongOwnerCannotCancelOrTakeOver() throws {
        let (service, power, _) = fixture(); let owner = UUID(), other = UUID()
        try service.begin(owner: owner, minutes: 0, now: 0, lidClosed: false)
        XCTAssertThrowsError(try service.begin(owner: other, minutes: 0, now: 1, lidClosed: false))
        XCTAssertThrowsError(try service.renew(owner: other, now: 2))
        try service.end(owner: other)
        XCTAssertTrue(power.value); XCTAssertTrue(service.active)
        try service.end(owner: owner)
        XCTAssertFalse(power.value)
    }
    func testJournalFailurePreventsMutation() {
        let (service, power, journal) = fixture(); journal.failSave = true
        XCTAssertThrowsError(try service.begin(owner: UUID(), minutes: 0, now: 0, lidClosed: false))
        XCTAssertEqual(power.writes, []); XCTAssertFalse(service.active)
    }
    func testPartialMutationRollsBack() {
        let (service, power, journal) = fixture(); power.failAfterMutation = true
        XCTAssertThrowsError(try service.begin(owner: UUID(), minutes: 0, now: 0, lidClosed: false))
        XCTAssertFalse(power.value); XCTAssertNil(journal.value); XCTAssertFalse(service.active)
    }
    func testRestoreFailureRetainsEvidenceAndRetries() throws {
        let (service, power, journal) = fixture(); let owner = UUID()
        try service.begin(owner: owner, minutes: 0, now: 0, lidClosed: false)
        power.rejectWrite = true
        XCTAssertThrowsError(try service.end(owner: owner))
        XCTAssertTrue(service.recoveryPending); XCTAssertNotNil(journal.value); XCTAssertTrue(power.value)
        power.rejectWrite = false
        try service.tick(now: 3, lidClosed: false, safe: true)
        XCTAssertFalse(power.value); XCTAssertNil(journal.value); XCTAssertFalse(service.recoveryPending)
    }
    func testCrashRecoveryUsesRecordedOriginalAndNeverArms() throws {
        let (_, power, journal) = fixture()
        for original in [false, true] {
            journal.value = SleepJournal(originalDisabled: original); power.value = true
            let restarted = SleepLease(power: power, journal: journal)
            try restarted.recover()
            XCTAssertEqual(power.value, original); XCTAssertNil(journal.value); XCTAssertFalse(restarted.active)
        }
    }
    func testSafetyLossSensorFailureAndDeadlineEndSession() throws {
        for failure in 0..<3 {
            let (service, power, _) = fixture(); let owner = UUID()
            try service.begin(owner: owner, minutes: 30, now: 0, lidClosed: false)
            if failure == 2 {
                for time in stride(from: 5, through: 1795, by: 5) { try service.renew(owner: owner, now: Double(time)) }
            }
            try service.tick(now: failure == 2 ? 1800 : 5,
                             lidClosed: failure == 1 ? nil : true, safe: failure != 0)
            XCTAssertFalse(service.active); XCTAssertFalse(power.value)
        }
    }
    func testRefusesPreexistingOverrideAndClosedLid() {
        let (service, power, journal) = fixture()
        power.value = true
        XCTAssertThrowsError(try service.begin(owner: UUID(), minutes: 0, now: 0, lidClosed: false))
        XCTAssertTrue(power.value); XCTAssertNil(journal.value)
        power.value = false
        XCTAssertThrowsError(try service.begin(owner: UUID(), minutes: 0, now: 0, lidClosed: true))
        XCTAssertFalse(power.value)
    }
    func testPowerdClamshellFlagReevaluationDoesNotReleaseGlobalSetting() throws {
        // Regression model for the observed WindowServer DMGrace timeout:
        // no selector12 bit is owned by this controller. Display wake/tickle
        // and AC/battery changes are not reasons to release its global setting.
        let (service, power, _) = fixture(); let owner = UUID()
        try service.begin(owner: owner, minutes: 0, now: 0, lidClosed: false)
        for second in 1...40 {
            if second % 5 == 0 { try service.renew(owner: owner, now: Double(second)) }
            try service.tick(now: Double(second), lidClosed: true, safe: true)
            XCTAssertTrue(power.value)
        }
        try service.end(owner: owner); XCTAssertFalse(power.value)
    }
    func testReadbackFailureNeverReportsActive() throws {
        let (service, power, journal) = fixture(); power.ignoreWrites = true
        XCTAssertThrowsError(try service.begin(owner: UUID(), minutes: 0, now: 0, lidClosed: false))
        XCTAssertFalse(service.active); XCTAssertFalse(power.value); XCTAssertNil(journal.value)
    }
    func testJournalClearFailureRetainsRecoveryState() throws {
        let (service, power, journal) = fixture(); let owner = UUID()
        try service.begin(owner: owner, minutes: 0, now: 0, lidClosed: false)
        journal.failClear = true
        XCTAssertThrowsError(try service.end(owner: owner))
        XCTAssertFalse(power.value); XCTAssertTrue(service.recoveryPending); XCTAssertNotNil(journal.value)
        journal.failClear = false
        try service.tick(now: 2, lidClosed: false, safe: true)
        XCTAssertFalse(service.recoveryPending); XCTAssertNil(journal.value)
    }
    func testRemovalPausesNewSessions() throws {
        let (service, power, _) = fixture()
        try service.begin(owner: UUID(), minutes: 0, now: 0, lidClosed: false)
        try service.pauseAndRestore()
        XCTAssertFalse(power.value)
        XCTAssertThrowsError(try service.begin(owner: UUID(), minutes: 0, now: 3, lidClosed: false))
    }
    func testDaemonCodeSigningRequirementCompiles() {
        var requirement: SecRequirement?
        XCTAssertEqual(SecRequirementCreateWithString(CompatibilityService.daemonRequirement as CFString, [], &requirement), errSecSuccess)
        XCTAssertTrue(CompatibilityService.name.hasPrefix(CompatibilityService.group + "."))
        XCTAssertFalse(CompatibilityService.daemonRequirement.contains("anchor trusted"))
    }
    func testMalformedTimeNeverExtendsLease() throws {
        let (service, power, _) = fixture(); let owner = UUID()
        XCTAssertThrowsError(try service.begin(owner: owner, minutes: 0, now: .nan, lidClosed: false))
        try service.begin(owner: owner, minutes: 0, now: 0, lidClosed: false)
        XCTAssertThrowsError(try service.renew(owner: owner, now: .infinity))
        XCTAssertFalse(power.value)
    }

    func testTransientReadFailureDuringRenewPreservesLeaseForRetry() throws {
        let (service, power, _) = fixture(); let owner = UUID()
        try service.begin(owner: owner, minutes: 0, now: 0, lidClosed: false)
        power.rejectRead = true
        XCTAssertThrowsError(try service.renew(owner: owner, now: 5))
        XCTAssertTrue(service.active)
        XCTAssertTrue(power.value)
        power.rejectRead = false
        try service.renew(owner: owner, now: 6)
        try service.tick(now: 35, lidClosed: true, safe: true)
        XCTAssertTrue(service.active)
        XCTAssertTrue(power.value)
    }

    func testTemporaryRemovalPauseExpiresAndDoesNotBrickDaemon() throws {
        let (service, power, _) = fixture()
        try service.begin(owner: UUID(), ownerUID: 501, minutes: 0, now: 10, lidClosed: false)
        XCTAssertEqual(service.activeOwnerUID, 501)
        try service.pauseAndRestore(now: 12, duration: 30)
        XCTAssertFalse(power.value)
        XCTAssertNil(service.activeOwnerUID)
        XCTAssertTrue(service.isPaused(at: 20))
        XCTAssertThrowsError(try service.begin(owner: UUID(), minutes: 0, now: 20, lidClosed: false))
        // After the 30-second removal window expires, a cancelled unregister leaves the daemon usable.
        XCTAssertFalse(service.isPaused(at: 42))
        try service.begin(owner: UUID(), ownerUID: 502, minutes: 0, now: 42, lidClosed: false)
        XCTAssertTrue(service.active)
        XCTAssertEqual(service.activeOwnerUID, 502)
        XCTAssertTrue(power.value)
    }

    func testRemovalPauseClearsWhenRestoreFails() throws {
        let (service, power, _) = fixture()
        try service.begin(owner: UUID(), minutes: 0, now: 0, lidClosed: false)
        power.rejectWrite = true
        XCTAssertThrowsError(try service.pauseAndRestore(now: 5, duration: 30))
        XCTAssertTrue(service.recoveryPending)
        XCTAssertFalse(service.isPaused(at: 6))
        power.rejectWrite = false
        try service.tick(now: 7, lidClosed: false, safe: true)
        XCTAssertFalse(service.recoveryPending)
        try service.begin(owner: UUID(), minutes: 0, now: 8, lidClosed: false)
        XCTAssertTrue(service.active)
    }
}
