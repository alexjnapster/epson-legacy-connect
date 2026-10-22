import Foundation
import PrinterCore

// Opt-in integration check: contacts official Epson hosts and caches their
// downloads locally. Does not install a package, accept a licence, or write USB.
@main enum ComponentChecks {
    static func main() async throws {
        let driver = try await OfficialComponents.shared.driverInstaller()
        let hash = try ComponentFiles.hash(driver)
        precondition(hash == EmbeddedDriver.expectedHash)
        let usb = try await OfficialComponents.shared.prepareUSBComponent()
        precondition(FileManager.default.fileExists(atPath: usb.licence.path))
        let signature = try CommandRunner.run("/usr/bin/codesign", ["--verify", "-R", "=anchor apple generic and identifier \"com.epson.print.plugin.XIOCBTm\" and certificate leaf[subject.OU] = \"TXAEAV5RN4\"", usb.plugin.path])
        precondition(signature.status == 0)
        print("PASS: official driver download, checksum, package signature, USB component extraction and Epson signature. No installation or printer writes performed.")
    }
}
