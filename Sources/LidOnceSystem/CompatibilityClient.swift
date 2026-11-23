import Foundation
import LidLidServiceProtocol

public struct CompatibilityStatus {
    public let active: Bool
    public let recoveryPending: Bool
}

/// Main-queue client; every call has a deadline. The service authenticates the
/// client signature and the client independently pins the daemon's signature.
public final class CompatibilityClient {
    private var connection: NSXPCConnection?
    public init() {}
    deinit { connection?.invalidate() }
    public func invalidate() {
        connection?.invalidationHandler = nil
        connection?.interruptionHandler = nil
        connection?.invalidate(); connection = nil
    }
    public func status(_ reply: @escaping (Result<CompatibilityStatus, Error>) -> Void) {
        call(timeoutSeconds: 6, reply: reply) { proxy, finish in
            proxy.status { version, active, pending in
                guard version == CompatibilityService.version else {
                    finish(.failure(PowerError(text: "请更新盖盖兼容组件")), true); return
                }
                finish(.success(CompatibilityStatus(active: active, recoveryPending: pending)), false)
            }
        }
    }
    public func begin(minutes: Int, _ reply: @escaping (Result<Void, Error>) -> Void) {
        command(timeoutSeconds: 10, reply: reply) { $0.beginSession(minutes: minutes, reply: $1) }
    }
    public func renew(_ reply: @escaping (Result<Void, Error>) -> Void) {
        command(timeoutSeconds: 6, reply: reply) { $0.renewSession(reply: $1) }
    }
    public func end(_ reply: @escaping (Result<Void, Error>) -> Void) {
        command(timeoutSeconds: 10, reply: reply) { $0.endSession(reply: $1) }
    }
    public func prepareForRemoval(_ reply: @escaping (Result<Void, Error>) -> Void) {
        command(timeoutSeconds: 10, reply: reply) { $0.prepareForRemoval(reply: $1) }
    }
    private func command(timeoutSeconds: TimeInterval,
                         reply: @escaping (Result<Void, Error>) -> Void,
                         operation: @escaping (LidLidSleepServiceProtocol, @escaping (Bool, String?) -> Void) -> Void) {
        call(timeoutSeconds: timeoutSeconds, reply: reply) { proxy, finish in
            operation(proxy) { success, message in
                // A clean RPC reply means the XPC channel is healthy; keep the
                // connection alive so transient daemon timeouts do not drop lease ownership.
                if success { finish(.success(()), false) }
                else { finish(.failure(PowerError(text: message ?? "兼容组件暂时不可用，请重新打开组件检查")), false) }
            }
        }
    }
    private func call<Value>(timeoutSeconds: TimeInterval,
                             reply: @escaping (Result<Value, Error>) -> Void,
                             operation: (LidLidSleepServiceProtocol, @escaping (Result<Value, Error>, Bool) -> Void) -> Void) {
        if connection == nil {
            let channel = NSXPCConnection(machServiceName: CompatibilityService.name, options: .privileged)
            channel.remoteObjectInterface = NSXPCInterface(with: LidLidSleepServiceProtocol.self)
            channel.setCodeSigningRequirement(CompatibilityService.daemonRequirement)
            channel.resume(); connection = channel
        }
        let current = connection!
        let gate = ReplyGate<Value> { [weak self] result, invalidateConnection in
            DispatchQueue.main.async {
                if invalidateConnection, self?.connection === current { self?.invalidate() }
                reply(result)
            }
        }
        let unavailable = PowerError(text: "请先安装并授权盖盖兼容组件")
        guard let proxy = current.remoteObjectProxyWithErrorHandler({ _ in gate.finish(.failure(unavailable), invalidate: true) }) as? LidLidSleepServiceProtocol else {
            gate.finish(.failure(unavailable), invalidate: true); return
        }
        let timeout = DispatchWorkItem {
            gate.finish(.failure(PowerError(text: "兼容组件响应超时，请保持开盖并检查组件")), invalidate: true)
        }
        gate.attach(timeout: timeout)
        DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: timeout)
        operation(proxy) { result, invalidate in gate.finish(result, invalidate: invalidate) }
    }
}

private final class ReplyGate<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: ((Result<Value, Error>, Bool) -> Void)?
    private var timeout: DispatchWorkItem?
    init(_ callback: @escaping (Result<Value, Error>, Bool) -> Void) { self.callback = callback }
    func attach(timeout: DispatchWorkItem) {
        lock.lock()
        if callback == nil { lock.unlock(); timeout.cancel(); return }
        self.timeout = timeout
        lock.unlock()
    }
    func finish(_ result: Result<Value, Error>, invalidate: Bool) {
        lock.lock()
        let callback = self.callback; self.callback = nil
        let timeout = self.timeout; self.timeout = nil
        lock.unlock()
        timeout?.cancel()
        callback?(result, invalidate)
    }
}
