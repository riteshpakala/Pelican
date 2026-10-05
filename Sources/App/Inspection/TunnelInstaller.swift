import Foundation
import PelicanKit
import SystemExtensions

/// Asks macOS to install or remove Pelican's network extension, and reports honestly what
/// happened.
///
/// macOS decides, not Pelican: it shows its own approval prompt in System Settings, and until
/// a person says yes nothing is installed. Several conditions are the system's to enforce —
/// the app must be in /Applications, signed, and carry the right entitlement — so the job here
/// is mostly to explain clearly when one of them is not met.
@MainActor
final class TunnelInstaller: NSObject {

    static let extensionIdentifier = "nyc.rao.pelican.tunnel"

    enum Outcome: Equatable {
        case installed
        case removed
        /// macOS accepted the request but needs the user to approve it in System Settings.
        case needsApproval
        /// Already installed at this version; nothing to do.
        case alreadyCurrent
        case failed(String)

        var line: String {
            switch self {
            case .installed: return "The extension is installed."
            case .removed: return "The extension has been removed."
            case .needsApproval:
                return "macOS is waiting for you to allow the extension in System Settings → General → Login Items & Extensions → Network Extensions."
            case .alreadyCurrent: return "The extension is already installed and up to date."
            case .failed(let why): return "The extension could not be installed: \(why)"
            }
        }
    }

    private var continuation: CheckedContinuation<Outcome, Never>?
    /// What was asked for, so the delegate can report the right outcome.
    private var pending: Kind = .install

    private enum Kind: Equatable { case install, remove }

    /// Why this Mac cannot install the extension, if it cannot. Checked before asking, so the
    /// reason is specific rather than a bare OS error code.
    static var blocker: String? {
        guard BuildInfo.isBundled else {
            return "Pelican is running from a build directory. The extension can only be installed from an app bundle: run ./scripts/make-app.sh --install first."
        }
        let path = Bundle.main.bundleURL.path
        guard path.hasPrefix("/Applications/") else {
            return "macOS only loads a system extension from an app in /Applications. Pelican is at \(path)."
        }
        let extensionPath = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/SystemExtensions")
            .appendingPathComponent("\(extensionIdentifier).systemextension")
        guard FileManager.default.fileExists(atPath: extensionPath.path) else {
            return "This copy of Pelican was built without the tunnel. Rebuild with PELICAN_APP_PROFILE and PELICAN_TUNNEL_PROFILE set to add it."
        }
        return nil
    }

    func install() async -> Outcome {
        if let blocker = Self.blocker { return .failed(blocker) }
        return await submit(.install, OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: Self.extensionIdentifier, queue: .main))
    }

    func remove() async -> Outcome {
        if !BuildInfo.isBundled { return .failed("Pelican is not running from an app bundle.") }
        return await submit(.remove, OSSystemExtensionRequest.deactivationRequest(
            forExtensionWithIdentifier: Self.extensionIdentifier, queue: .main))
    }

    private func submit(_ kind: Kind, _ request: OSSystemExtensionRequest) async -> Outcome {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.pending = kind
            request.delegate = self
            OSSystemExtensionManager.shared.submitRequest(request)
        }
    }

    private func finish(_ outcome: Outcome) {
        let waiting = continuation
        continuation = nil
        waiting?.resume(returning: outcome)
    }
}

extension TunnelInstaller: OSSystemExtensionRequestDelegate {

    nonisolated func request(_ request: OSSystemExtensionRequest,
                             didFinishWithResult result: OSSystemExtensionRequest.Result) {
        MainActor.assumeIsolated {
            switch result {
            case .completed:
                finish(pending == .install ? .installed : .removed)
            case .willCompleteAfterReboot:
                finish(.failed("macOS will finish this after a restart."))
            @unknown default:
                finish(.failed("macOS returned an unfamiliar result."))
            }
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        MainActor.assumeIsolated { finish(.failed(Self.explain(error))) }
    }

    /// macOS is showing its approval prompt. Nothing happens until the user agrees.
    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        MainActor.assumeIsolated { finish(.needsApproval) }
    }

    /// An extension is already installed; say whether to replace it.
    nonisolated func request(_ request: OSSystemExtensionRequest,
                             actionForReplacingExtension existing: OSSystemExtensionProperties,
                             withExtension new: OSSystemExtensionProperties)
        -> OSSystemExtensionRequest.ReplacementAction {
        existing.bundleVersion == new.bundleVersion
            && existing.bundleShortVersion == new.bundleShortVersion ? .cancel : .replace
    }

    /// Turn the OS's error codes into something a person can act on.
    static func explain(_ error: Error) -> String {
        guard let failure = error as? OSSystemExtensionError else { return error.localizedDescription }
        switch failure.code {
        case .authorizationRequired:
            return "macOS needs you to approve this in System Settings → General → Login Items & Extensions → Network Extensions."
        case .extensionNotFound:
            return "macOS could not find the extension inside Pelican.app."
        case .validationFailed:
            return "macOS rejected the extension's signature or entitlements. The app and the extension must be signed with matching provisioning profiles."
        case .forbiddenBySystemPolicy:
            return "System policy refused the extension. On a managed Mac this is usually an MDM profile; otherwise check that Pelican is in /Applications."
        case .requestCanceled:
            return "The request was cancelled."
        case .requestSuperseded:
            return "A newer request replaced this one."
        case .codeSignatureInvalid:
            return "The extension's code signature is not valid."
        case .unsupportedParentBundleLocation:
            return "macOS only loads a system extension from an app in /Applications."
        default:
            return "\(failure.localizedDescription) (code \(failure.code.rawValue))"
        }
    }
}
