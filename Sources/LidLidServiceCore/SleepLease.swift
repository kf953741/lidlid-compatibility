import Foundation

public struct ServiceFailure: LocalizedError {
    public let errorDescription: String?
    public init(_ text: String) { errorDescription = text }
}

public protocol SleepSetting {
    func read() throws -> Bool
    func write(disabled: Bool) throws
}

/// This is a SYSTEM-WIDE setting, not a per-power-source Energy Saver setting.
/// See Apple's pmset.m, parseArgs/system_power_settings. Never infer its value
/// from `pmset -g custom`, where it is absent.
public struct SleepJournal: Codable, Equatable {
    public let schema: Int
    public let originalDisabled: Bool
    public init(originalDisabled: Bool) { self.schema = 1; self.originalDisabled = originalDisabled }
}

public protocol SleepJournalStore {
    func load() throws -> SleepJournal?
    func save(_ journal: SleepJournal) throws
    func clear() throws
}

/// Caller serializes all operations. Time is injected from a continuous clock,
/// not wall time (clock changes or sleep must not extend a stale lease).
public final class SleepLease {
    private let power: SleepSetting
    private let journal: SleepJournalStore
    private var owner: UUID?
    private var ownerUID: UInt32?
    private var expiry: TimeInterval = 0
    private var deadline: TimeInterval?
    private var sawClosed = false
    private var permanentPause = false
    private var pausedUntil: TimeInterval?
    public private(set) var recoveryPending = false
    public var active: Bool { owner != nil }
    public var activeOwnerUID: UInt32? { ownerUID }

    public init(power: SleepSetting, journal: SleepJournalStore) {
        self.power = power; self.journal = journal
    }

    public func isPaused(at now: TimeInterval) -> Bool {
        if permanentPause { return true }
        guard let until = pausedUntil else { return false }
        if now.isFinite && now < until { return true }
        pausedUntil = nil
        return false
    }

    public func recover() throws {
        owner = nil; ownerUID = nil; deadline = nil
        try restore()
    }
    public func begin(owner id: UUID, ownerUID: UInt32? = nil, minutes: Int, now: TimeInterval, lidClosed: Bool) throws {
        guard !isPaused(at: now) else { throw ServiceFailure("兼容组件正在移除，请重新安装后再试") }
        guard [0, 30, 60, 120, 240, 480].contains(minutes), now.isFinite, !lidClosed else {
            throw ServiceFailure("请先打开电脑盖子")
        }
        guard owner == nil else { throw ServiceFailure("另一个盖盖会话正在运行") }
        try restore()
        let original = try power.read()
        guard !original else { throw ServiceFailure("其他程序正在接管睡眠，请先关闭它的防睡眠功能") }
        // Durably journal BEFORE mutation, including the partial-failure case.
        try journal.save(SleepJournal(originalDisabled: original))
        recoveryPending = true
        do {
            try power.write(disabled: true)
            guard try power.read() else { throw ServiceFailure("兼容组件未能确认睡眠设置，请稍后重试") }
        } catch {
            try? restore()
            throw error
        }
        owner = id; self.ownerUID = ownerUID; expiry = now + 30
        // A journal during a healthy session is intentional, not a recovery
        // failure. Active ownership already keeps the daemon's timer running.
        recoveryPending = false
        deadline = minutes == 0 ? nil : now + Double(minutes * 60)
        sawClosed = false
    }
    public func renew(owner id: UUID, now: TimeInterval) throws {
        guard owner == id, now.isFinite, now < expiry, deadline.map({ now < $0 }) ?? true else {
            if owner == id { try recover() }
            throw ServiceFailure("兼容组件会话已结束，请重新开启")
        }
        guard try power.read() else {
            try recover()
            throw ServiceFailure("睡眠设置被其他程序更改，本次已结束")
        }
        expiry = now + 30
    }
    public func end(owner id: UUID) throws {
        guard owner == id || owner == nil else { return }
        try recover()
    }
    public func tick(now: TimeInterval, lidClosed: Bool?, safe: Bool) throws {
        if let until = pausedUntil, now.isFinite, now >= until {
            pausedUntil = nil
        }
        if owner != nil {
            guard let closed = lidClosed, safe, now.isFinite, now < expiry,
                  deadline.map({ now < $0 }) ?? true else { try recover(); return }
            if sawClosed && !closed { try recover(); return }
            sawClosed = sawClosed || closed
        } else {
            try restore()
        }
    }
    public func pauseAndRestore(now: TimeInterval? = nil, duration: TimeInterval = 30) throws {
        if let now, now.isFinite {
            pausedUntil = now + max(1, duration)
            do {
                try recover()
            } catch {
                pausedUntil = nil
                throw error
            }
        } else {
            permanentPause = true
            try recover()
        }
    }
    private func restore() throws {
        do {
            guard let saved = try journal.load() else { recoveryPending = false; return }
            guard saved.schema == 1 else { throw ServiceFailure("兼容组件恢复记录版本不匹配，请联系支持") }
            recoveryPending = true
            try power.write(disabled: saved.originalDisabled)
            guard try power.read() == saved.originalDisabled else {
                throw ServiceFailure("恢复尚未确认，正在重试；请保持开盖")
            }
            try journal.clear()
            recoveryPending = false
        } catch { recoveryPending = true; throw error }
    }
}
