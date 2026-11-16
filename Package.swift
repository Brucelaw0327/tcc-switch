// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TCCSwitch",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "TCCSwitch", targets: ["TCCSwitch"])
    ],
    targets: [
        .executableTarget(
            name: "TCCSwitch",
            path: "Sources/TCCSwitch",
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit")
            ]
        )
    ],
    // SwiftUI + ObservableObject 在 Swift 6 严格并发下会与 actor 隔离产生大量冲突；
    // 这里固定 Swift 5 语言模式，IO 仍全部走 CommandRunner actor 隔离，安全边界不变。
    swiftLanguageModes: [.v5]
)
