// swift-tools-version: 6.0
// Pelican — an open-source, observe-only network monitor for macOS, and a live trust monitor
// for Rao's apps: it watches every connection their processes make and checks each one
// against the consent the user gave. Capture: NetworkStatistics socket events plus nettop.
// Analysis: an on-device Mistral MLX model (via the Frigate package).
//
// Build:   swift build --build-system native      (see README: the default engine trips on
//                                                   Frigate's .metal sources on some setups)
// Run:     ./scripts/build-metallib.sh && swift run --build-system native Pelican
// App:     ./scripts/make-app.sh      Installer: ./scripts/make-pkg.sh
//
// PIN: Frigate is a sibling checkout by path (FRIGATE_DIR overrides). Support/Info.plist is
//      embedded into the binary with -sectcreate so `swift run` has a bundle identity and
//      version; make-app.sh copies the same plist into the .app. Its LSMinimumSystemVersion
//      must match `platforms` below — make-app.sh checks.

import Foundation
import PackageDescription

let frigatePath = Context.environment["FRIGATE_DIR"] ?? "../../rao/repositories/Frigate"

let package = Package(
    name: "Pelican",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: frigatePath),
    ],
    targets: [
        .executableTarget(
            name: "Pelican",
            dependencies: [
                .product(name: "MLXLLM", package: "Frigate"),
                .product(name: "MLXLMCommon", package: "Frigate"),
                .product(name: "MLX", package: "Frigate"),
                .product(name: "FrigateBridge", package: "Frigate"),
            ],
            path: "Sources",
            // MLX's ModelContext and friends are non-Sendable; same setting Fleet uses.
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "\(Context.packageDirectory)/Support/Info.plist",
                ]),
            ]
        ),
        .testTarget(
            name: "PelicanTests",
            dependencies: ["Pelican"],
            path: "Tests/PelicanTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
