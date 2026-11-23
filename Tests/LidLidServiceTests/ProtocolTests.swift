import XCTest
import Foundation
import LidLidServiceProtocol

private final class StubEndpoint: NSObject, LidLidSleepServiceProtocol {
    func status(reply: @escaping (Int, Bool, Bool) -> Void) { reply(CompatibilityService.version, false, false) }
    func beginSession(minutes: Int, reply: @escaping (Bool, String?) -> Void) { reply(minutes == 30, nil) }
    func renewSession(reply: @escaping (Bool, String?) -> Void) { reply(true, nil) }
    func endSession(reply: @escaping (Bool, String?) -> Void) { reply(true, nil) }
    func prepareForRemoval(reply: @escaping (Bool, String?) -> Void) { reply(false, "test refusal") }
}
private final class StubListener: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: LidLidSleepServiceProtocol.self)
        connection.exportedObject = StubEndpoint()
        connection.resume(); return true
    }
}
final class ProtocolTests: XCTestCase {
    func testXPCMessageRoundTripWithoutRootOrPowerChanges() throws {
        // Anonymous in-process transport test only. The installed daemon uses
        // a named listener with pinned code-signing requirements instead.
        let listener = NSXPCListener.anonymous(), delegate = StubListener()
        listener.delegate = delegate; listener.resume()
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: LidLidSleepServiceProtocol.self)
        connection.resume()
        defer { connection.invalidate(); listener.invalidate() }
        let completed = expectation(description: "protocol replies")
        let proxy = try XCTUnwrap(connection.remoteObjectProxyWithErrorHandler { error in
            XCTFail(error.localizedDescription); completed.fulfill()
        } as? LidLidSleepServiceProtocol)
        proxy.status { version, active, recovery in
            XCTAssertEqual(version, CompatibilityService.version); XCTAssertFalse(active); XCTAssertFalse(recovery)
            proxy.beginSession(minutes: 30) { success, _ in
                XCTAssertTrue(success)
                proxy.renewSession { success, _ in
                    XCTAssertTrue(success)
                    proxy.endSession { success, _ in
                        XCTAssertTrue(success)
                        proxy.prepareForRemoval { success, message in
                            XCTAssertFalse(success); XCTAssertEqual(message, "test refusal"); completed.fulfill()
                        }
                    }
                }
            }
        }
        withExtendedLifetime(delegate) { wait(for: [completed], timeout: 6) }
    }
}
