import Foundation
import CryptoKit

public enum EmbeddedDriver {
    public static let version = "13.45"
    public static let expectedHash = "5e596d0673bc382328642e6f3fb748064be6b5b2ba9566a89d72a60e87db2910"
    public static func verifiedInstaller() throws -> URL {
        let cached = ComponentFiles.directory.appendingPathComponent("EPSON Printer.pkg")
        guard let url = Bundle.main.url(forResource: "EPSON Printer", withExtension: "pkg", subdirectory: "Vendor") ?? (FileManager.default.fileExists(atPath: cached.path) ? cached : nil),
              let input = InputStream(url: url) else {
            throw failure("The bundled Epson installer is missing. Download a complete copy of this app.")
        }
        var digest = SHA256()
        input.open(); defer { input.close() }
        var bytes = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = input.read(&bytes, maxLength: bytes.count)
            guard count >= 0 else { throw failure("The bundled Epson installer could not be read.") }
            if count == 0 { break }
            digest.update(data: Data(bytes.prefix(count)))
        }
        let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
        guard hash == expectedHash else {
            throw failure("The Epson installer has changed. Installation was stopped.")
        }
        let signature = try CommandRunner.run("/usr/sbin/pkgutil", ["--check-signature", url.path], timeout: 20)
        guard signature.status == 0, !signature.timedOut,
              signature.output.contains("Developer ID Installer: Seiko Epson Corporation (TXAEAV5RN4)"),
              signature.output.contains("signed by a developer certificate issued by Apple") else {
            throw failure("macOS could not verify Epson's installer signature. Installation was stopped.")
        }
        return url
    }
    private static func failure(_ message: String) -> NSError {
        NSError(domain: "EmbeddedDriver", code: 1, userInfo: [NSLocalizedDescriptionKey: L(message)])
    }
}
