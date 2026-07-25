// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AudioConvert",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "AudioConvert",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            exclude: ["Info.plist"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ],
            // Info.plist embutido: fornece NSAudioCaptureUsageDescription para o
            // TCC solicitar a permissão de captura de áudio num binário sem bundle.
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "\(Context.packageDirectory)/Sources/AudioConvert/Info.plist",
                ])
            ]
        ),
    ]
)
