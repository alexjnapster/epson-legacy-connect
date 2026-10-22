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
        print("PASS: 13 core checks")
    }
}
