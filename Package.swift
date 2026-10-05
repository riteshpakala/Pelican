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
// Modules: PelicanKit (capture, flows, process identity; Foundation only) ← PelicanUI (design
//          system) and PelicanAnalyst (the only module linking MLX) ← PelicanRao (everything
//          about Rao's apps, isolated) ← Pelican (the app). Feature modules never import each
//          other or the app; cross-module API is `package`, never `public`.
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
        // The inspection engine's TLS and HTTP. Apple's own, rather than hand-written: a relay
        // that gets TLS subtly wrong would be worse than no inspection at all. They are linked
        // only by PelicanIntercept, never by the app's other modules.
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.27.0"),
        .package(url: "https://github.com/apple/swift-nio-http2.git", from: "1.35.0"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.6.0"),
    ],
    targets: [
        .target(
            name: "PelicanKit",
            path: "Sources/Kit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "PelicanUI",
            dependencies: ["PelicanKit"],
            path: "Sources/UI",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "PelicanAnalyst",
            dependencies: [
                "PelicanKit",
                .product(name: "MLXLLM", package: "Frigate"),
                .product(name: "MLXLMCommon", package: "Frigate"),
                .product(name: "MLX", package: "Frigate"),
                .product(name: "FrigateBridge", package: "Frigate"),
            ],
            path: "Sources/Analyst",
            // MLX's ModelContext and friends are non-Sendable; same setting Fleet uses.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "PelicanRao",
            dependencies: ["PelicanKit", "PelicanUI"],
            path: "Sources/Rao",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "PelicanIntercept",
            dependencies: [
                "PelicanKit",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOTLS", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "NIOHPACK", package: "swift-nio-http2"),
                .product(name: "X509", package: "swift-certificates"),
            ],
            path: "Sources/Intercept",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "PelicanGuard",
            dependencies: ["PelicanKit", "PelicanUI"],
            path: "Sources/Guard",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "PelicanAITools",
            dependencies: ["PelicanKit", "PelicanUI"],
            path: "Sources/AITools",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Pelican",
            dependencies: ["PelicanKit", "PelicanUI", "PelicanAnalyst", "PelicanRao",
                           "PelicanAITools", "PelicanGuard", "PelicanTunnelProtocol"],
            path: "Sources/App",
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
            name: "PelicanKitTests",
            dependencies: ["PelicanKit"],
            path: "Tests/PelicanKitTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "PelicanRaoTests",
            dependencies: ["PelicanKit", "PelicanRao"],
            path: "Tests/PelicanRaoTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The small contract between the app and the extension. Foundation only, so the root
        // extension stays minimal.
        .target(
            name: "PelicanTunnelProtocol",
            path: "Sources/TunnelProtocol",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The network system extension. macOS runs it as root, so besides the shared protocol
        // it links nothing but the system frameworks — no Pelican module, no third-party code.
        .executableTarget(
            name: "PelicanTunnel",
            dependencies: ["PelicanTunnelProtocol"],
            path: "Sources/Tunnel",
            swiftSettings: [.swiftLanguageMode(.v5)],
            // audit_token_to_pid, for reading which process a flow belongs to.
            linkerSettings: [.linkedLibrary("bsm")]
        ),
        .testTarget(
            name: "PelicanInterceptTests",
            dependencies: ["PelicanKit", "PelicanIntercept"],
            path: "Tests/PelicanInterceptTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "PelicanGuardTests",
            dependencies: ["PelicanKit", "PelicanGuard"],
            path: "Tests/PelicanGuardTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "PelicanAIToolsTests",
            dependencies: ["PelicanKit", "PelicanAITools"],
            path: "Tests/PelicanAIToolsTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
