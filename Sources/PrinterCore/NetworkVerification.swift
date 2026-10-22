import Foundation
import Network

public enum NetworkVerification {
    public static func usableIPv4(_ address: String) -> Bool {
        let components = address.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4 else { return false }
        var octets: [Int] = []
        for component in components {
            guard !component.isEmpty, component.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let octet = Int(component), (0...255).contains(octet) else { return false }
            octets.append(octet)
        }
        return (1...223).contains(octets[0]) && octets[0] != 127 && !(octets[0] == 169 && octets[1] == 254)
    }

    /// Open and close a TCP connection, without sending a print job.
    public static func printPortReachable(_ address: String) -> Bool {
        guard usableIPv4(address) || address.range(of: #"^[A-Za-z0-9][A-Za-z0-9-]{0,62}\.local\.?$"#, options: .regularExpression) != nil else { return false }
        let connection = NWConnection(host: NWEndpoint.Host(address), port: 9100, using: .tcp)
        let queue = DispatchQueue(label: "local.photo1500.verify")
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var reachable = false
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: lock.lock(); reachable = true; lock.unlock(); semaphore.signal()
            case .failed, .cancelled: semaphore.signal()
            default: break
            }
        }
        connection.start(queue: queue)
        _ = semaphore.wait(timeout: .now() + 5)
        connection.cancel()
        lock.lock(); defer { lock.unlock() }
        return reachable
    }
}
