// swift-tools-version: 6.0
import Foundation
import PackageDescription

// MARK: - Command Line Tools testing shim
//
// The CLT-only toolchain ships `Testing.framework` and its macro plugin outside the
// search paths SwiftPM adds automatically, so `import Testing` otherwise fails with
// "no such module 'Testing'". Xcode-based toolchains resolve Swift Testing natively and
// must not get these flags (they could shadow a newer framework), so inject them only
// when the active developer directory is the Command Line Tools.
//
// Note: the Command Line Tools also lack the `xctest` harness. With CLT only, `swift test`
// builds and links the test bundle but cannot execute it (it exits 0 with no test output).
// Run `swift test` on an Xcode toolchain to actually execute the suite.
let cltRoot = "/Library/Developer/CommandLineTools"
let cltTestingFramework = cltRoot + "/Library/Developer/Frameworks/Testing.framework"
// `xcode-select` records the active developer directory in this symlink. When an Xcode
// toolchain is selected, Swift Testing and XCTest are resolved by SwiftPM already.
let selectedDeveloperDir = ProcessInfo.processInfo.environment["DEVELOPER_DIR"]
    ?? (try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link"))
    ?? cltRoot
let usingXcodeToolchain = selectedDeveloperDir.contains(".app/Contents/Developer")
let needsCLTTestingShim = !usingXcodeToolchain
    && FileManager.default.fileExists(atPath: cltTestingFramework)

let testingSwiftSettings: [SwiftSetting] = needsCLTTestingShim
    ? [
        .unsafeFlags([
            "-F", cltRoot + "/Library/Developer/Frameworks",
            "-plugin-path", cltRoot + "/usr/lib/swift/host/plugins/testing",
            // The CLT ships a dangling `_Testing_Foundation` cross-import overlay.
            "-Xfrontend", "-disable-cross-import-overlay-search"
        ])
    ]
    : []

let testingLinkerSettings: [LinkerSetting] = needsCLTTestingShim
    ? [
        .unsafeFlags([
            "-F", cltRoot + "/Library/Developer/Frameworks",
            "-Xlinker", "-rpath", "-Xlinker", cltRoot + "/Library/Developer/Frameworks"
        ])
    ]
    : []

let package = Package(
    name: "UsageCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "UsageCore", targets: ["UsageCore"])
    ],
    targets: [
        .target(
            name: "UsageCore",
            path: "Sources/UsageCore"
        ),
        .testTarget(
            name: "UsageCoreTests",
            dependencies: ["UsageCore"],
            path: "Tests/UsageCoreTests",
            resources: [
                .copy("Fixtures")
            ],
            swiftSettings: testingSwiftSettings,
            linkerSettings: testingLinkerSettings
        )
    ],
    swiftLanguageModes: [.v6]
)
