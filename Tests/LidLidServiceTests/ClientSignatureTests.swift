import Foundation
import Security
import XCTest
@testable import LidLidServiceAuth

final class ClientSignatureTests: XCTestCase {
    private let betaWorker = URL(fileURLWithPath: "/Applications/LidLid.app/Contents/Helpers/LidLidAgent")

    func testRejectsUnrelatedAppleSignedExecutable() {
        XCTAssertThrowsError(try SleepServiceClientAuthentication.inspectExecutable(
            at: URL(fileURLWithPath: "/usr/bin/true")))
    }

    func testRejectsAdHocImpostorWithForgedTeamEntitlement() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("impostor")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executable)
        let entitlements = directory.appendingPathComponent("forged.plist")
        try PropertyListSerialization.data(fromPropertyList: [
            "com.apple.developer.team-identifier": "63ALH54858",
            "com.apple.application-identifier": "63ALH54858.dev.kf.lidonce.agent"
        ], format: .xml, options: 0).write(to: entitlements)
        let signer = Process()
        signer.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        signer.arguments = ["--force", "--sign", "-", "--identifier", "dev.kf.lidonce.agent",
                            "--entitlements", entitlements.path, executable.path]
        signer.standardOutput = FileHandle.nullDevice
        signer.standardError = FileHandle.nullDevice
        try signer.run(); signer.waitUntilExit()
        XCTAssertEqual(signer.terminationStatus, 0)
        XCTAssertThrowsError(try SleepServiceClientAuthentication.inspectExecutable(at: executable))
    }

    func testRealBetaWorkerUsesSignedTeamAndHash() throws {
        guard FileManager.default.fileExists(atPath: betaWorker.path) else {
            throw XCTSkip("Local Apple-distributed build is an optional integration fixture")
        }
        let signature = try SleepServiceClientAuthentication.inspectExecutable(at: betaWorker)
        XCTAssertEqual(signature.identifier, "dev.kf.lidonce.agent")
        XCTAssertEqual(signature.team, "63ALH54858")
        XCTAssertEqual(signature.cdhash.count, 40)
        // Same team, different signed executable: the peer pin must reject it.
        var requirement: SecRequirement?
        XCTAssertEqual(SecRequirementCreateWithString(signature.connectionRequirement as CFString, [], &requirement), errSecSuccess)
        var other: SecStaticCode?
        XCTAssertEqual(SecStaticCodeCreateWithPath(URL(fileURLWithPath: "/Applications/LidLid.app") as CFURL, [], &other), errSecSuccess)
        XCTAssertNotEqual(SecStaticCodeCheckValidity(other!, [], requirement), errSecSuccess)
    }

    func testBetaCertificateDoesNotAuthorizeADifferentTeam() throws {
        guard FileManager.default.fileExists(atPath: betaWorker.path) else {
            throw XCTSkip("Local Apple-distributed build is an optional integration fixture")
        }
        var code: SecStaticCode?
        XCTAssertEqual(SecStaticCodeCreateWithPath(betaWorker as CFURL, [], &code), errSecSuccess)
        XCTAssertThrowsError(try SleepServiceClientAuthentication.validate(code!, expectedTeam: "OTHERTEAM"))
    }

    func testRunningBetaClientCanBeAuthenticated() throws {
        guard let value = ProcessInfo.processInfo.environment["LIDLID_TEST_BETA_PID"],
              let pid = Int32(value) else {
            throw XCTSkip("Set LIDLID_TEST_BETA_PID for the live TestFlight integration check")
        }
        let signature = try SleepServiceClientAuthentication.authenticate(processIdentifier: pid)
        XCTAssertEqual(signature.team, "63ALH54858")
        XCTAssertTrue(["dev.kf.lidonce", "dev.kf.lidonce.agent"].contains(signature.identifier))
        XCTAssertEqual(signature.cdhash.count, 40)
    }
}
