import Foundation
import NetworkExtension

// The system extension's entry point. macOS launches this binary as root, inside the
// Pelican.app bundle, once the user has approved the extension in System Settings.
//
// It does as little as possible on purpose: see TunnelProvider.
autoreleasepool {
    NEProvider.startSystemExtensionMode()
}

dispatchMain()
