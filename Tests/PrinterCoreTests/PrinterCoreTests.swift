import Foundation
import PrinterCore

final class PrinterCoreTests {
    func testQueueParsingDoesNotSplitURIColons() {
        let queues = PrinterQueue.parse("device for Photo_1500: socket://192.168.86.2:9100\ndevice for USB: usb://EPSON/1500?serial=123\nnoise")
        XCTAssertEqual(queues.count, 2)
        XCTAssertEqual(queues[0].uri, "socket://192.168.86.2:9100")
        XCTAssertTrue(queues[0].isNetwork)
        XCTAssertTrue(queues[1].isUSB)
    }
    func testQueueNamesCannotBecomeOptions() {
        XCTAssertTrue(PrinterQueue.parse("device for bad name: usb://EPSON/1500").isEmpty)
    }
    func testUnknownInkIsNotDisplayedAsZero() {
        let inks = InkLevel.parse(names: "Black,Cyan,Yellow", levels: "-1,101,0")
        XCTAssertNil(inks[0].percent)
        XCTAssertNil(inks[1].percent)
        XCTAssertEqual(inks[2].percent, 0)
        XCTAssertTrue(InkLevel.parse(names: "Black,Cyan", levels: "50").isEmpty)
    }
    func testSSIDLengthUsesBytesRatherThanCharacterCount() {
        XCTAssertThrowsError(try WiFiCredentials.validate(ssid: String(repeating: "Ж", count: 17), password: "valid password"))
        XCTAssertNoThrow(try WiFiCredentials.validate(ssid: String(repeating: "Ж", count: 16), password: "valid password"))
    }
    func testWPAKeyValidation() {
        XCTAssertThrowsError(try WiFiCredentials.validate(ssid: "Home", password: "short"))
        XCTAssertThrowsError(try WiFiCredentials.validate(ssid: "Home", password: String(repeating: "z", count: 64)))
        XCTAssertNoThrow(try WiFiCredentials.validate(ssid: "Home", password: String(repeating: "f", count: 64)))
        XCTAssertNoThrow(try WiFiCredentials.validate(ssid: " Home ", password: "with spaces"))
    }
    func testControlCharactersRejected() {
        XCTAssertThrowsError(try WiFiCredentials.validate(ssid: "Home\nOther", password: "valid password"))
        XCTAssertThrowsError(try WiFiCredentials.validate(ssid: "Home", password: "valid\npassword"))
    }
    func testRunnerPreservesLiteralArguments() throws {
        let value = "$(echo should-not-run); `echo neither`"
        let result = try CommandRunner.run("/usr/bin/printf", ["%s", value])
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output, value)
    }
    func testRunnerTimeout() throws {
        let start = Date()
        let result = try CommandRunner.run("/bin/sleep", ["10"], timeout: 0.1)
        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }
    func testConfigurationXMLAndEscaping() throws {
        let request = try USBConfiguration.wifiRequest(ssid: "Home & <Studio>", password: "secret<&> password")
        let doc = try XMLDocument(data: request)
        let dataNode = try doc.nodes(forXPath: "//*[local-name()='Data']").first as? XMLElement
        XCTAssertEqual(dataNode?.uri, "http://schemas.epson.net/ws/2008/07/config-data")
        let ssid = try doc.nodes(forXPath: "//*[@id='ijcp:SSIDEdit']").first?.stringValue
        let key = try doc.nodes(forXPath: "//*[@id='ijcp:SecurityKey']").first?.stringValue
        XCTAssertEqual(ssid, "Home & <Studio>")
        XCTAssertEqual(key, "secret<&> password")
        XCTAssertThrowsError(try USBConfiguration.setRequest(groups: [("Injected<", [("key", "value")])]))
    }
    func testReplyStructureAndFaults() throws {
        func envelope(_ group: String) -> Data {
            Data("<s:Envelope xmlns:s='http://www.w3.org/2003/05/soap-envelope'><s:Body><c:GetDataResponse xmlns:c='http://schemas.epson.net/ws/2008/07/config'><Data xmlns='http://schemas.epson.net/ws/2008/07/config-data'>\(group)</Data></c:GetDataResponse></s:Body></s:Envelope>".utf8)
        }
        let fields = try ConfigurationResponse.parse(envelope("<Group id='ijcp:NWDataInfo' return='true'><d id='ijcp:IPAddress'>192.168.86.25</d></Group>"))
        XCTAssertEqual(fields["ijcp:NWDataInfo"]?["ijcp:IPAddress"], "192.168.86.25")
        XCTAssertThrowsError(try ConfigurationResponse.parse(envelope("<Group id='ijcp:NWDataInfo' return='false'/>")))
        XCTAssertThrowsError(try ConfigurationResponse.parse(envelope("<Group id='ijcp:NWDataInfo' return='true'><d id='ijcp:X'>1</d><d id='ijcp:X'>2</d></Group>")))
        XCTAssertThrowsError(try ConfigurationResponse.parse(Data("<fake><GetDataResponse xmlns='http://schemas.epson.net/ws/2008/07/config'/></fake>".utf8)))
        XCTAssertThrowsError(try ConfigurationResponse.parse(Data("<!DOCTYPE doc [<!ENTITY secret SYSTEM 'file:///etc/passwd'>]><doc>&secret;</doc>".utf8)))
    }
    func testNetworkAddressValidation() {
        for address in ["0.0.0.0", "127.0.0.1", "169.254.4.5", "224.0.0.1", "192.168.1.999", "host.local", "192.168.1.2;ls", "192.168.1."] {
            XCTAssertTrue(!NetworkVerification.usableIPv4(address))
        }
        XCTAssertTrue(NetworkVerification.usableIPv4("192.168.86.25"))
    }
    func testModelProfilesUseExactAliases() {
        XCTAssertEqual(PrinterProfiles.match("EPSON Epson Stylus Photo 1500")?.id, "photo-1500")
        XCTAssertEqual(PrinterProfiles.match("EPSON XP-850 Series")?.id, "xp-850")
        XCTAssertNil(PrinterProfiles.match("XP-850 Series modified"))
        XCTAssertNil(PrinterProfiles.match("Unknown Epson Model"))
        XCTAssertTrue(PrinterProfiles.all.filter(\.wifiHardwareVerified).map(\.id) == ["photo-1500"])
    }
    func testQueueRejectsInjectedOrRemoteHosts() {
        XCTAssertThrowsError(try WirelessQueue.install(host: "printer.local;echo injected"))
        XCTAssertThrowsError(try WirelessQueue.install(host: "example.com"))
        XCTAssertThrowsError(try WirelessQueue.install(host: "-E.local", model: "Unlisted model"))
    }
    func testCareCapabilitiesRequireEpsonCommandSupport() {
        let attrs = """
        printer-make-and-model (textWithoutLanguage) = EPSON SP 1500 Series
        document-format-supported (1setOf mimeMediaType) = application/pdf,application/vnd.cups-command
        printer-commands (1setOf keyword) = Clean,PrintSelfTestPage,ReportLevels
        """
        XCTAssertEqual(PrinterCare.supportedActions(in: attrs), CareAction.allCases)
        XCTAssertTrue(PrinterCare.supportedActions(in: attrs.replacingOccurrences(of: "EPSON SP", with: "OTHER SP")).isEmpty)
        XCTAssertTrue(PrinterCare.supportedActions(in: attrs.replacingOccurrences(of: "application/vnd.cups-command", with: "text/plain")).isEmpty)
        XCTAssertEqual(PrinterCare.supportedActions(in: attrs.replacingOccurrences(of: "Clean,PrintSelfTestPage,ReportLevels", with: "ReportLevels,Unknown")), [.inkLevels])
    }
    func testCareJobsAreBoundToSelectedQueue() {
        XCTAssertEqual(PrinterCare.jobNumber(in: "request id is Epson_Photo-42 (1 file(s))\n", queue: "Epson_Photo"), 42)
        XCTAssertNil(PrinterCare.jobNumber(in: "request id is Other-42 (1 file(s))", queue: "Epson_Photo"))
        XCTAssertNil(PrinterCare.jobNumber(in: "request id is Epson_Photo-0 (1 file(s))", queue: "Epson_Photo"))
        XCTAssertNil(PrinterCare.jobNumber(in: "request id is Epson_Photo-42;rm (1 file(s))", queue: "Epson_Photo"))
        for name in ["-bad", "../other", "name with spaces", "a/other", "a\n", ""] { XCTAssertTrue(!PrinterCare.validQueue(name)) }
        XCTAssertEqual(CareJobState(rawValue: "completed"), .completed)
        XCTAssertTrue(!CareJobState.processing.terminal)
        XCTAssertTrue(CareJobState.aborted.terminal)
        XCTAssertEqual(String(decoding: CareAction.cleanHeads.commandFile, as: UTF8.self), "#CUPS-COMMAND\nClean all\n")
    }
    func testScanStatusNeverAcceptsUnknownOrRejectedResults() throws {
        func reply(_ value: String, accepted: String = "true") -> Data {
            Data("<s:Envelope xmlns:s='http://www.w3.org/2003/05/soap-envelope'><s:Body><c:GetDataResponse xmlns:c='http://schemas.epson.net/ws/2008/07/config'><Data xmlns='http://schemas.epson.net/ws/2008/07/config-data'><Group id='ijcp:SSIDScan' return='\(accepted)'><d id='ijcp:SSIDScan'>\(value)</d></Group></Data></c:GetDataResponse></s:Body></s:Envelope>".utf8)
        }
        XCTAssertEqual(try WirelessScanStatus.parse(reply("1")), .running)
        XCTAssertEqual(try WirelessScanStatus.parse(reply("2")), .complete)
        XCTAssertThrowsError(try WirelessScanStatus.parse(reply("0")))
        XCTAssertThrowsError(try WirelessScanStatus.parse(reply("2", accepted: "false")))
        XCTAssertThrowsError(try WirelessScanStatus.parse(reply("malformed")))
    }

    func testJobParsingIsBoundToQueueAndRejectsMalformedIDs() {
        let output = "Photo_Queue-42 user 1024 Thu Oct 22 16:00:00 2026\nOther-43 user 2048 Thu Oct 22\nPhoto_Queue-0 user 1 Thu Oct 22\nPhoto_Queue-bad user 1 Thu Oct 22\nPhoto_Queue-45 user -1 Thu Oct 22"
        let jobs = PrintJob.parse(output, queue: "Photo_Queue")
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(jobs.first?.id, 42)
        XCTAssertEqual(jobs.first?.bytes, 1024)
        XCTAssertEqual(jobs.first?.queue, "Photo_Queue")
        XCTAssertTrue(PrintJob.parse(output, queue: "../Photo_Queue").isEmpty)
        XCTAssertTrue(PrintJob.parse("Photo_Queue-+42 user 1 Thu Oct 22", queue: "Photo_Queue").isEmpty)
    }

    func testPowerParametersAreSeparateFromUITimerValues() {
        XCTAssertEqual(PowerOffTimer.allCases.map(\.firmwareParameter), [255, 2, 4, 8, 12])
        XCTAssertEqual(PowerOffTimer.alwaysOn.rawValue, 0)
    }

    func testBridgeElectionIsStableAndExcludesUnreadyHosts() {
        let now = Date(timeIntervalSince1970: 100)
        let first = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let second = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        func candidate(_ id: UUID, age: Double = 0, ready: Bool = true, reachable: Bool = true, hosting: Bool = false, printer: String = "test-printer") -> BridgeCandidate {
            BridgeCandidate(id: id, printerID: printer, lastSeen: now.addingTimeInterval(-age), driverReady: ready, printerReachable: reachable, hosting: hosting)
        }
        func leader(_ candidates: [BridgeCandidate]) -> UUID? { BridgeElection.leader(for: "test-printer", candidates: candidates, now: now) }
        XCTAssertEqual(leader([candidate(second), candidate(first)]), first)
        XCTAssertEqual(leader([candidate(first), candidate(second, hosting: true)]), second)
        XCTAssertEqual(leader([candidate(second, hosting: true), candidate(first, hosting: true)]), first)
        XCTAssertEqual(leader([candidate(first, age: 15, hosting: true), candidate(second)]), second)
        XCTAssertEqual(leader([candidate(first, ready: false), candidate(second)]), second)
        XCTAssertEqual(leader([candidate(first, reachable: false), candidate(second)]), second)
        XCTAssertNil(leader([candidate(first, printer: "other-printer")]))
        XCTAssertNil(leader([candidate(first, age: -1)]))
        XCTAssertNil(leader([candidate(first), candidate(first)]))
        XCTAssertNil(leader([]))
    }

    func testAirPrintArgumentsRejectInjectedOptionsAndUnsupportedFormats() throws {
        let environment = ["CONTENT_TYPE": "image/urf", "IPP_COPIES": "2", "IPP_MEDIA": "iso_a4_210x297mm", "IPP_PRINT_COLOR_MODE": "monochrome"]
        let arguments = try AirPrintJob.arguments(queue: "Photo_Queue", file: "/tmp/test.urf", environment: environment)
        XCTAssertEqual(arguments.prefix(4).map { $0 }, ["-d", "Photo_Queue", "-t", "AirPrint document"])
        XCTAssertTrue(arguments.contains("EPIJ_Ink_=0"))
        XCTAssertEqual(arguments.last, "/tmp/test.urf")
        XCTAssertThrowsError(try AirPrintJob.arguments(queue: "-bad", file: "/tmp/test.urf", environment: environment))
        XCTAssertThrowsError(try AirPrintJob.arguments(queue: "Photo", file: "/tmp/test.ps", environment: ["CONTENT_TYPE": "application/postscript"]))
        XCTAssertThrowsError(try AirPrintJob.arguments(queue: "Photo", file: "/tmp/test.urf", environment: ["CONTENT_TYPE": "image/urf", "IPP_COPIES": "2 -d Other"]))
        XCTAssertThrowsError(try AirPrintJob.arguments(queue: "Photo", file: "/tmp/test.urf", environment: ["CONTENT_TYPE": "image/urf", "IPP_MEDIA": "A4 copies=100"]))
        XCTAssertTrue(AirPrintJob.validMediaCollection("{media-size={x-dimension=21000 y-dimension=29700} media-type=stationery}"))
        for value in ["{} copies=99 {}", "{media=A4", "{media=$(command)}", "{media=A4}\n"] { XCTAssertTrue(!AirPrintJob.validMediaCollection(value)) }
    }

}

// Standalone checks also run with Apple's Command Line Tools, where XCTest
// is not shipped. Any failed assertion exits nonzero with its source location.
func XCTAssertTrue(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) {
    precondition(value, "Expected true", file: file, line: line)
}
func XCTAssertEqual<T: Equatable>(_ lhs: T, _ rhs: T, file: StaticString = #filePath, line: UInt = #line) {
    precondition(lhs == rhs, "Values differ", file: file, line: line)
}
func XCTAssertNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) {
    precondition(value == nil, "Expected nil", file: file, line: line)
}
func XCTAssertLessThan<T: Comparable>(_ lhs: T, _ rhs: T, file: StaticString = #filePath, line: UInt = #line) {
    precondition(lhs < rhs, "Expected smaller value", file: file, line: line)
}
func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    do { _ = try expression() } catch { return }
    preconditionFailure("Expected an error", file: file, line: line)
}
func XCTAssertNoThrow<T>(_ expression: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    do { _ = try expression() } catch { preconditionFailure("Unexpected error: \(error)", file: file, line: line) }
}

@main enum CoreChecks {
    static func main() throws {
        let tests = PrinterCoreTests()
        tests.testQueueParsingDoesNotSplitURIColons()
        tests.testQueueNamesCannotBecomeOptions()
        tests.testUnknownInkIsNotDisplayedAsZero()
        tests.testSSIDLengthUsesBytesRatherThanCharacterCount()
        tests.testWPAKeyValidation()
        tests.testControlCharactersRejected()
        try tests.testRunnerPreservesLiteralArguments()
        try tests.testRunnerTimeout()
        try tests.testConfigurationXMLAndEscaping()
        try tests.testReplyStructureAndFaults()
        tests.testNetworkAddressValidation()
        tests.testModelProfilesUseExactAliases()
        tests.testQueueRejectsInjectedOrRemoteHosts()
        tests.testCareCapabilitiesRequireEpsonCommandSupport()
        tests.testCareJobsAreBoundToSelectedQueue()
        try tests.testScanStatusNeverAcceptsUnknownOrRejectedResults()
        tests.testJobParsingIsBoundToQueueAndRejectsMalformedIDs()
        tests.testPowerParametersAreSeparateFromUITimerValues()
        tests.testBridgeElectionIsStableAndExcludesUnreadyHosts()
        try tests.testAirPrintArgumentsRejectInjectedOptionsAndUnsupportedFormats()
        print("PASS: 20 core checks")
    }
}
