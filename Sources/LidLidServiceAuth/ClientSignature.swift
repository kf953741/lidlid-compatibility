import Foundation
import Security
import LidLidServiceProtocol

public struct ClientSignature {
    public let identifier: String
    public let team: String
    public let cdhash: String

    /// XPC checks this against its original peer, not a subsequently reused PID.
    public var connectionRequirement: String {
        "anchor apple generic and identifier \"\(identifier)\" and cdhash H\"\(cdhash)\""
    }
}

public enum ClientSignatureError: Error {
    case security(OSStatus)
    case identity
    case hash
}

public enum SleepServiceClientAuthentication {
    // App Store and TestFlight replace the developer's leaf certificate. Their
    // Apple-owned certificate OIDs come from Apple's TN3127 and the installed
    // TestFlight build's designated requirement. They do not identify our team:
    // verify the signed CodeDirectory team below before accepting either one.
    private static let provenance = """
    anchor apple generic and (
      certificate leaf[subject.OU] = "\(CompatibilityService.team)" or
      certificate leaf[field.1.2.840.113635.100.6.1.9] exists or
      certificate leaf[field.1.2.840.113635.100.6.1.25.1] exists
    )
    """

    public static func authenticate(processIdentifier: pid_t) throws -> ClientSignature {
        guard processIdentifier > 0 else { throw ClientSignatureError.identity }
        var guest: SecCode?
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: processIdentifier)] as CFDictionary
        try check(SecCodeCopyGuestWithAttributes(nil, attributes, [], &guest))
        guard let guest else { throw ClientSignatureError.identity }
        let requirement = try compile(provenance)
        try check(SecCodeCheckValidity(guest, [], requirement))
        var code: SecStaticCode?
        try check(SecCodeCopyStaticCode(guest, [], &code))
        guard let code else { throw ClientSignatureError.identity }
        return try validate(code)
    }

    /// Read-only packaging/integration check; this does not grant an XPC session.
    public static func inspectExecutable(at url: URL) throws -> ClientSignature {
        var code: SecStaticCode?
        try check(SecStaticCodeCreateWithPath(url as CFURL, [], &code))
        guard let code else { throw ClientSignatureError.identity }
        return try validate(code)
    }

    static func validate(_ code: SecStaticCode,
                         expectedTeam: String = CompatibilityService.team) throws -> ClientSignature {
        try check(SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), try compile(provenance)))
        var information: CFDictionary?
        try check(SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information))
        guard let information = information as? [String: Any],
              let identifier = information[kSecCodeInfoIdentifier as String] as? String,
              CompatibilityService.clientIdentifiers.contains(identifier),
              let team = information[kSecCodeInfoTeamIdentifier as String] as? String,
              team == expectedTeam else { throw ClientSignatureError.identity }
        guard let hash = information[kSecCodeInfoUnique as String] as? Data,
              hash.count == 20 else { throw ClientSignatureError.hash }
        let result = ClientSignature(identifier: identifier, team: team,
                                     cdhash: hash.map { String(format: "%02x", $0) }.joined())
        // Check the generated requirement before passing it to Foundation.
        try check(SecStaticCodeCheckValidity(code, [], try compile(result.connectionRequirement)))
        return result
    }

    private static func compile(_ text: String) throws -> SecRequirement {
        var requirement: SecRequirement?
        try check(SecRequirementCreateWithString(text as CFString, [], &requirement))
        guard let requirement else { throw ClientSignatureError.identity }
        return requirement
    }

    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw ClientSignatureError.security(status) }
    }
}
