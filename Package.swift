// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "EpsonWiFiAssistant",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "EpsonWiFiAssistant", targets: ["EpsonWiFiAssistant"]),
               .executable(name: "EpsonAirPrintBackend", targets: ["EpsonAirPrintBackend"])],
    targets: [
        .target(name: "NativeUSB", linkerSettings: [.linkedFramework("Foundation"), .linkedFramework("Security")]),
        .target(name: "PrinterCore", dependencies: ["NativeUSB"]),
        .executableTarget(name: "EpsonWiFiAssistant", dependencies: ["PrinterCore"], exclude: ["Resources"]),
        .executableTarget(name: "EpsonAirPrintBackend", dependencies: ["PrinterCore"]),
        .executableTarget(name: "PrinterCoreChecks", dependencies: ["PrinterCore"], path: "Tests/PrinterCoreTests"),
        .executableTarget(name: "ComponentChecks", dependencies: ["PrinterCore"], path: "Tests/ComponentChecks")
    ]
)
