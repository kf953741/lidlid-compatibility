import Foundation

public enum CompatibilityService {
    public static let version = 1
    public static let team = "63ALH54858"
    public static let group = "\(team).dev.kf.lidonce"
    public static let name = "\(group).sleep-service"
    public static let plist = "\(name).plist"
    public static let helperID = "dev.kf.lidonce.compatibility"
    public static let daemonID = "dev.kf.lidonce.sleep-service"
    public static let leaseSeconds: TimeInterval = 30
    public static let renewalSeconds: TimeInterval = 5
    public static let daemonRequirement = "anchor apple generic and identifier \"\(daemonID)\" and certificate leaf[subject.OU] = \"\(team)\""
    // The worker inherits the parent's sandbox, but has its own signing ID.
    // ServiceAuth also verifies the actual signing team and pins each XPC peer.
    public static let clientIdentifiers: Set<String> = [
        "dev.kf.lidonce", "dev.kf.lidonce.agent", helperID
    ]
}

@objc public protocol LidLidSleepServiceProtocol {
    func status(reply: @escaping (Int, Bool, Bool) -> Void)
    func beginSession(minutes: Int, reply: @escaping (Bool, String?) -> Void)
    func renewSession(reply: @escaping (Bool, String?) -> Void)
    func endSession(reply: @escaping (Bool, String?) -> Void)
    func prepareForRemoval(reply: @escaping (Bool, String?) -> Void)
}
