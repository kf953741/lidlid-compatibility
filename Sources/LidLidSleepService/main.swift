import Darwin
import Foundation
import SystemConfiguration
import OSLog
import LidLidServiceCore
import LidLidServiceProtocol
import LidLidServiceAuth
import LidOnceSystem

let logger = Logger(subsystem: CompatibilityService.daemonID, category: "sleep")
let epoch = ContinuousClock.now
let serviceQueue = DispatchQueue(label: "dev.kf.lidonce.sleep-service.work", qos: .userInitiated)
func now() -> TimeInterval {
    let components = epoch.duration(to: .now).components
    return Double(components.seconds) + Double(components.attoseconds) / 1e18
}
func consoleUser(_ uid: uid_t) -> Bool {
    var current: uid_t = 0
    _ = SCDynamicStoreCopyConsoleUser(nil, &current, nil)
    return uid != 0 && current == uid
}

final class ServiceStateMirror: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false
    private var recoveryPending = false
    private var inFlightMutations = 0

    func beginMutation() {
        lock.lock()
        inFlightMutations += 1
        lock.unlock()
    }

    func endMutation(active: Bool, recoveryPending: Bool) {
        lock.lock()
        inFlightMutations = max(0, inFlightMutations - 1)
        self.active = active
        self.recoveryPending = recoveryPending
        lock.unlock()
    }

    func update(active: Bool, recoveryPending: Bool) {
        lock.lock()
        self.active = active
        self.recoveryPending = recoveryPending
        lock.unlock()
    }

    func read() -> (active: Bool, recoveryPending: Bool) {
        lock.lock()
        defer { lock.unlock() }
        // Never report all-clear while a begin/end/removal mutation is in flight.
        return (active, recoveryPending || inFlightMutations > 0)
    }
}

final class ServiceEndpoint: NSObject, LidLidSleepServiceProtocol {
    let id = UUID()
    let uid: uid_t
    let clientIdentifier: String
    let controller: SleepLease
    let power: PowerDriver
    let mirror: ServiceStateMirror
    private let stateLock = NSLock()
    private var isDisconnected = false

    init(uid: uid_t, clientIdentifier: String, controller: SleepLease, power: PowerDriver, mirror: ServiceStateMirror) {
        self.uid = uid
        self.clientIdentifier = clientIdentifier
        self.controller = controller
        self.power = power
        self.mirror = mirror
    }
    private func markDisconnected() {
        stateLock.lock()
        isDisconnected = true
        stateLock.unlock()
    }
    private func checkDisconnected() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isDisconnected
    }
    func status(reply: @escaping (Int, Bool, Bool) -> Void) {
        let snapshot = mirror.read()
        reply(CompatibilityService.version, snapshot.active, snapshot.recoveryPending)
    }
    func beginSession(minutes: Int, reply: @escaping (Bool, String?) -> Void) {
        perform(reply) {
            guard !self.checkDisconnected() else { throw ServiceFailure("兼容组件会话已结束，请重新开启") }
            guard consoleUser(self.uid), self.safe(), self.power.bool("AppleClamshellState") == false else {
                throw ServiceFailure("请保持开盖，确认电量、温度和显示器状态后重试")
            }
            try self.controller.begin(owner: self.id, ownerUID: self.uid, minutes: minutes, now: now(), lidClosed: false)
            if self.checkDisconnected() {
                try? self.controller.end(owner: self.id)
                throw ServiceFailure("兼容组件会话已结束，请重新开启")
            }
            logger.notice("Session began; original system sleep setting journaled")
        }
    }
    func renewSession(reply: @escaping (Bool, String?) -> Void) {
        perform(reply) {
            guard !self.checkDisconnected(), consoleUser(self.uid), self.safe() else {
                try self.controller.end(owner: self.id)
                throw ServiceFailure("电量、温度或用户状态改变，本次已结束")
            }
            try self.controller.renew(owner: self.id, now: now())
        }
    }
    func endSession(reply: @escaping (Bool, String?) -> Void) {
        perform(reply) { try self.controller.end(owner: self.id) }
    }
    func prepareForRemoval(reply: @escaping (Bool, String?) -> Void) {
        perform(reply) {
            guard self.clientIdentifier == CompatibilityService.helperID, consoleUser(self.uid) else {
                throw ServiceFailure("兼容服务需要 macOS 管理员授权")
            }
            // Temporary pause window lets SMAppService.unregister() finish cleanly
            // without permanently bricking the daemon if the user cancels the prompt.
            try self.controller.pauseAndRestore(now: now(), duration: 30)
        }
    }
    func disconnected() {
        markDisconnected()
        mirror.beginMutation()
        serviceQueue.async {
            do { try self.controller.end(owner: self.id) }
            catch { logger.error("Disconnect recovery pending: \(error.localizedDescription, privacy: .public)") }
            self.mirror.endMutation(active: self.controller.active, recoveryPending: self.controller.recoveryPending)
        }
    }
    private func perform(_ reply: @escaping (Bool, String?) -> Void, operation: @escaping () throws -> Void) {
        mirror.beginMutation()
        serviceQueue.async {
            do {
                try operation()
                self.mirror.endMutation(active: self.controller.active, recoveryPending: self.controller.recoveryPending)
                reply(true, nil)
            } catch {
                self.mirror.endMutation(active: self.controller.active, recoveryPending: self.controller.recoveryPending)
                logger.error("Service operation: \(error.localizedDescription, privacy: .public)")
                reply(false, error.localizedDescription)
            }
        }
    }
    /// Root LaunchDaemon intentionally avoids CoreGraphics/WindowServer display
    /// queries (which require an Aqua GUI session); display checks run in the
    /// user-session worker instead.
    func safe() -> Bool {
        let battery = batteryReading()
        return battery.percent != nil && (!battery.onBattery || battery.percent! > 10)
            && ProcessInfo.processInfo.thermalState.rawValue < ProcessInfo.ThermalState.serious.rawValue
    }
}

final class Listener: NSObject, NSXPCListenerDelegate {
    let controller: SleepLease
    let power: PowerDriver
    let mirror: ServiceStateMirror
    init(controller: SleepLease, power: PowerDriver, mirror: ServiceStateMirror) {
        self.controller = controller; self.power = power; self.mirror = mirror
    }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard consoleUser(connection.effectiveUserIdentifier) else { return false }
        guard let signature = try? SleepServiceClientAuthentication.authenticate(
            processIdentifier: connection.processIdentifier) else { return false }
        // PID lookup alone is insufficient: XPC must bind the validated hash to
        // its original peer before exporting an object or resuming messages.
        connection.setCodeSigningRequirement(signature.connectionRequirement)
        let service = ServiceEndpoint(uid: connection.effectiveUserIdentifier,
                                      clientIdentifier: signature.identifier,
                                      controller: controller, power: power, mirror: mirror)
        connection.exportedInterface = NSXPCInterface(with: LidLidSleepServiceProtocol.self)
        connection.exportedObject = service
        connection.invalidationHandler = { service.disconnected() }
        connection.interruptionHandler = { service.disconnected() }
        connection.resume()
        return true
    }
}

if CommandLine.arguments.contains("--self-test") {
    // Pure parser check: never registers a service or changes power settings.
    let parsedExplicit = try! SystemSleepSetting.parse("System-wide power settings:\n SleepDisabled 0\n")
    precondition(parsedExplicit == false)
    let parsedFresh = try! SystemSleepSetting.parse("System-wide power settings:\nCurrently in use:\n standby 1\n")
    precondition(parsedFresh == false)
    let parsedEnabled = try! SystemSleepSetting.parse("System-wide power settings:\n SleepDisabled 1\n")
    precondition(parsedEnabled == true)
    print("LidLid sleep service parser passed; no settings changed")
    exit(0)
}
guard geteuid() == 0 else { fputs("Start this service through the compatibility app and macOS approval.\n", stderr); exit(1) }
do {
    let power = try PowerDriver()
    let controller = SleepLease(power: SystemSleepSetting(root: power), journal: try RootJournal())
    let mirror = ServiceStateMirror()
    // Recover before exposing XPC. A failure stays alive and retries instead of
    // forgetting a persistent override after a crash, SIGKILL, or power loss.
    do { try controller.recover() }
    catch { logger.fault("Startup restoration pending: \(error.localizedDescription, privacy: .public)") }
    mirror.update(active: controller.active, recoveryPending: controller.recoveryPending)
    let delegate = Listener(controller: controller, power: power, mirror: mirror)
    let listener = NSXPCListener(machServiceName: CompatibilityService.name)
    listener.delegate = delegate
    listener.resume()
    let timer = DispatchSource.makeTimerSource(queue: serviceQueue)
    timer.schedule(deadline: .now(), repeating: 1)
    timer.setEventHandler {
        guard controller.active || controller.recoveryPending else { return }
        let battery = batteryReading()
        var current: uid_t = 0
        _ = SCDynamicStoreCopyConsoleUser(nil, &current, nil)
        let ownerMatches = controller.activeOwnerUID.map { current != 0 && current == $0 } ?? true
        let safe = ownerMatches && battery.percent != nil && (!battery.onBattery || battery.percent! > 10)
            && ProcessInfo.processInfo.thermalState.rawValue < ProcessInfo.ThermalState.serious.rawValue
        do { try controller.tick(now: now(), lidClosed: power.bool("AppleClamshellState"), safe: safe) }
        catch { logger.error("Restoration retry pending: \(error.localizedDescription, privacy: .public)") }
        mirror.update(active: controller.active, recoveryPending: controller.recoveryPending)
    }
    timer.resume()
    var signals: [DispatchSourceSignal] = []
    for code in [SIGTERM, SIGINT] {
        signal(code, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: code, queue: serviceQueue)
        source.setEventHandler {
            do {
                try controller.pauseAndRestore()
                mirror.update(active: controller.active, recoveryPending: controller.recoveryPending)
                exit(0)
            } catch {
                mirror.update(active: controller.active, recoveryPending: controller.recoveryPending)
                logger.fault("Shutdown recovery retained on disk: \(error.localizedDescription, privacy: .public)")
                exit(1)
            }
        }
        source.resume(); signals.append(source)
    }
    withExtendedLifetime((listener, delegate, timer, signals)) { RunLoop.main.run() }
} catch { logger.fault("Service initialization failed: \(error.localizedDescription, privacy: .public)"); exit(1) }
