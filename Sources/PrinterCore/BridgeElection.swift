import Foundation

/// Election policy only. Networking/advertisement must verify each candidate's
/// heartbeat and capability before supplying it here. It never migrates jobs.
public struct BridgeCandidate: Sendable {
    public let id: UUID
    public let printerID: String
    public let lastSeen: Date
    public let driverReady: Bool
    public let printerReachable: Bool
    public let hosting: Bool
    public init(id: UUID, printerID: String, lastSeen: Date, driverReady: Bool, printerReachable: Bool, hosting: Bool) {
        self.id = id; self.printerID = printerID; self.lastSeen = lastSeen
        self.driverReady = driverReady; self.printerReachable = printerReachable; self.hosting = hosting
    }
}

public enum BridgeElection {
    public static func leader(for printerID: String, candidates: [BridgeCandidate], now: Date, lease: TimeInterval = 15) -> UUID? {
        guard !printerID.isEmpty, lease > 0, lease <= 120 else { return nil }
        // Conflicting duplicate IDs are excluded rather than interpreted as two hosts.
        let counts = Dictionary(grouping: candidates, by: \.id).mapValues(\.count)
        let live = candidates.filter {
            let age = now.timeIntervalSince($0.lastSeen)
            return $0.printerID == printerID && $0.driverReady && $0.printerReachable &&
                age >= 0 && age < lease && counts[$0.id] == 1
        }
        // Keep a healthy active host stable when a new Mac joins. If two hosts
        // appear during simultaneous startup, the same ordering resolves both.
        let active = live.filter(\.hosting)
        return (active.isEmpty ? live : active).map(\.id).min { $0.uuidString < $1.uuidString }
    }
}
