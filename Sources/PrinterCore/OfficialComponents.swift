import Foundation
import CryptoKit

public enum ComponentFiles {
    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EpsonLegacyConnect/Components", isDirectory: true)
    }
    public static let usbConsentVersion = "XIOCBTm-3.01-ECPSU-200"
    public static func hash(_ url: URL) throws -> String {
        guard let input = InputStream(url: url) else { throw ConfigurationError.componentMissing }
        input.open(); defer { input.close() }
        var digest = SHA256(), bytes = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = input.read(&bytes, maxLength: bytes.count)
            guard count >= 0 else { throw input.streamError ?? ConfigurationError.invalidReply }
            if count == 0 { break }
            digest.update(data: Data(bytes.prefix(count)))
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    public static func verifyPackage(_ url: URL) throws {
        let result = try CommandRunner.run("/usr/sbin/pkgutil", ["--check-signature", url.path], timeout: 30)
        guard result.status == 0, !result.timedOut,
              result.output.contains("Developer ID Installer: Seiko Epson Corporation (TXAEAV5RN4)"),
              result.output.contains("signed by a developer certificate issued by Apple") else {
            throw failure("macOS could not verify Epson's installer signature. Installation was stopped.")
        }
    }
    public static func failure(_ message: String) -> NSError {
        NSError(domain: "OfficialComponents", code: 1, userInfo: [NSLocalizedDescriptionKey: L(message)])
    }
}

public struct PreparedUSBComponent: Sendable {
    public let plugin: URL
    public let licence: URL
}

/// Official Epson downloads stay on the user's Mac, outside the signed app.
/// No vendor software is needed in the source repository or public app archive.
public actor OfficialComponents {
    public static let shared = OfficialComponents()
    private var busy = false
    public func driverInstaller() async throws -> URL {
        if let existing = try? EmbeddedDriver.verifiedInstaller() { return existing }
        guard !busy else { throw ComponentFiles.failure("Another component download is running. Please wait.") }
        busy = true; defer { busy = false }
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let image = try await download("https://download.epson-europe.com/pub/download/6790/epson679095eu.dmg", to: workspace)
        let mount = workspace.appendingPathComponent("volume")
        try attach(image, at: mount)
        defer { detach(mount) }
        let package = mount.appendingPathComponent("EPSON Printer.pkg")
        guard try ComponentFiles.hash(package) == EmbeddedDriver.expectedHash else { throw ComponentFiles.failure("The Epson installer has changed. Installation was stopped.") }
        try ComponentFiles.verifyPackage(package)
        let destination = ComponentFiles.directory.appendingPathComponent("EPSON Printer.pkg")
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.copyItem(at: package, to: destination)
        return try EmbeddedDriver.verifiedInstaller()
    }

    public func prepareUSBComponent() async throws -> PreparedUSBComponent {
        let saved = ComponentFiles.directory.appendingPathComponent("XIOCBTm.plugin")
        let licence = ComponentFiles.directory.appendingPathComponent("Epson-USB-Licence.html")
        if FileManager.default.fileExists(atPath: saved.path), FileManager.default.fileExists(atPath: licence.path) {
            return PreparedUSBComponent(plugin: saved, licence: licence)
        }
        guard !busy else { throw ComponentFiles.failure("Another component download is running. Please wait.") }
        busy = true; defer { busy = false }
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let image = try await download("https://ftp.epson.com/drivers/ECPSU_200.dmg", to: workspace)
        guard try ComponentFiles.hash(image) == "9c95b7d46e3727b72ab1fa30507499d99dfe1b80dbc1ba32aeada942d8e9f32b" else { throw ComponentFiles.failure("The Epson download has changed. Update the app before continuing.") }
        let mount = workspace.appendingPathComponent("volume")
        try attach(image, at: mount)
        defer { detach(mount) }
        let packages = try FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil).filter { $0.pathExtension == "pkg" }
        guard packages.count == 1 else { throw ConfigurationError.componentMissing }
        try ComponentFiles.verifyPackage(packages[0])
        let expanded = workspace.appendingPathComponent("expanded")
        let expansion = try CommandRunner.run("/usr/sbin/pkgutil", ["--expand-full", packages[0].path, expanded.path], timeout: 60)
        guard expansion.status == 0, !expansion.timedOut else { throw ConfigurationError.componentMissing }
        let app = expanded.appendingPathComponent("ECPS1100.pkg/Payload/Applications/Epson Software/Epson Connect Printer Setup.app/Contents")
        let plugin = app.appendingPathComponent("PlugIns/BS/XIOCBTm.plugin")
        let originalLicence = app.appendingPathComponent("Resources/en.lproj/EULA.html")
        guard FileManager.default.fileExists(atPath: plugin.path), FileManager.default.fileExists(atPath: originalLicence.path) else { throw ConfigurationError.componentMissing }
        if FileManager.default.fileExists(atPath: saved.path) { try FileManager.default.removeItem(at: saved) }
        if FileManager.default.fileExists(atPath: licence.path) { try FileManager.default.removeItem(at: licence) }
        try FileManager.default.copyItem(at: plugin, to: saved)
        try FileManager.default.copyItem(at: originalLicence, to: licence)
        return PreparedUSBComponent(plugin: saved, licence: licence)
    }

    private func makeWorkspace() throws -> URL {
        try FileManager.default.createDirectory(at: ComponentFiles.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("EpsonLegacyConnect-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }
    private func download(_ address: String, to workspace: URL) async throws -> URL {
        var request = URLRequest(url: URL(string: address)!)
        request.timeoutInterval = 120
        let (temporary, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              response.url?.scheme == "https",
              ["ftp.epson.com", "download.epson-europe.com"].contains(response.url?.host ?? "") else { throw ComponentFiles.failure("The official Epson download could not be completed.") }
        let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard (1...200_000_000).contains(size) else { throw ConfigurationError.invalidReply }
        let target = workspace.appendingPathComponent("official.dmg")
        try FileManager.default.moveItem(at: temporary, to: target)
        return target
    }
    private func attach(_ image: URL, at mount: URL) throws {
        let result = try CommandRunner.run("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-mountpoint", mount.path, image.path], timeout: 30)
        guard result.status == 0, !result.timedOut else { throw ComponentFiles.failure("The Epson download could not be opened.") }
    }
    private func detach(_ mount: URL) { _ = try? CommandRunner.run("/usr/bin/hdiutil", ["detach", mount.path], timeout: 15) }
}
