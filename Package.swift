// swift-tools-version: 6.0
// Pelican — a Little Snitch-style, observe-only network monitor for macOS with
// on-device LLM analysis. Polls userspace tools (nettop) for per-process
// incoming/outgoing flows and analyzes them in-process with a Mistral MLX model
// (via the Frigate package), using preset or custom threat-hunting prompts.
//
// Standalone SwiftPM executable (mirrors Fleet/Client): swift run Pelican.

import PackageDescription

let package = Package(
    name: "Pelican",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "/Users/ritesh/Documents/rao/repositories/Frigate"),
    ],
    targets: [
        .executableTarget(
            name: "Pelican",
            dependencies: [
                .product(name: "MLXLLM", package: "Frigate"),
                .product(name: "MLXLMCommon", package: "Frigate"),
                .product(name: "MLX", package: "Frigate"),
            ],
            path: "Sources",
            // MLX's ModelContext and friends are non-Sendable; same setting Fleet uses.
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
