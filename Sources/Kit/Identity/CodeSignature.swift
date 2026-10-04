import Foundation
import Security

/// What macOS reports about a running process's code signature. Pelican embeds no team IDs
/// or certificate names: it shows these observed values and applies generic consistency
/// rules (RaoIdentityAuditor), so anyone can compare them with what a vendor publishes.
package struct CodeSignature: Sendable, Equatable, Codable {

    /// The certificate class, from Apple's generic leaf-name prefixes.
    package enum LeafKind: String, Sendable, Codable {
        case developerID        // "Developer ID Application: …" — distributed outside the App Store
        case appleDevelopment   // "Apple Development: …" / "Mac Developer: …" — a developer's own build
        case appleDistribution  // "Apple Distribution: …" / "3rd Party Mac Developer Application: …"
        case apple              // Apple's own software
        case other
        case none               // ad-hoc or unsigned: no certificate at all

        package var displayName: String {
            switch self {
            case .developerID: return "Developer ID"
            case .appleDevelopment: return "Apple Development"
            case .appleDistribution: return "App Store distribution"
            case .apple: return "Apple"
            case .other: return "other certificate"
            case .none: return "no certificate"
            }
        }

        package static func classify(_ subject: String?) -> LeafKind {
            guard let subject else { return .none }
            if subject.hasPrefix("Developer ID Application") { return .developerID }
            if subject.hasPrefix("Apple Development") || subject.hasPrefix("Mac Developer") { return .appleDevelopment }
            if subject.hasPrefix("Apple Distribution") || subject.hasPrefix("3rd Party Mac Developer")
                || subject.hasPrefix("Apple Mac OS Application Signing") { return .appleDistribution }
            if subject.hasPrefix("Software Signing")
                || subject.hasPrefix("macOS Software Signing") { return .apple }
            return .other
        }
    }

    package var identifier: String?
    package var teamIdentifier: String?
    package var leafSubject: String?
    package var leafKind: LeafKind
    package var isValid: Bool
    package var validityError: String?
    package var isAdHoc: Bool
    package var hardenedRuntime: Bool
    package var linkerSigned: Bool
    package var cdHash: String?
    package var designatedRequirement: String?
    /// Apple notarized this code (it satisfies the `notarized` code requirement). nil when
    /// not checked.
    package var notarized: Bool?

    /// A build its developer made for themselves: nothing ties it to a release.
    package var isDevelopmentBuild: Bool {
        isAdHoc || linkerSigned || leafKind == .appleDevelopment || leafKind == .none || !hardenedRuntime
    }

    /// Why `isDevelopmentBuild` is true, in words.
    package var developmentReasons: [String] {
        var reasons: [String] = []
        if isAdHoc || leafKind == .none { reasons.append(linkerSigned ? "linker-signed (ad-hoc)" : "ad-hoc signed") }
        else if leafKind == .appleDevelopment { reasons.append("signed with an Apple Development certificate") }
        if !hardenedRuntime && !(isAdHoc || leafKind == .none) { reasons.append("no hardened runtime") }
        return reasons
    }

    // Code-signing flag bits (kSecCodeInfoFlags).
    private static let flagAdHoc: UInt32 = 0x0002
    private static let flagRuntime: UInt32 = 0x1_0000
    private static let flagLinkerSigned: UInt32 = 0x2_0000

    /// Read the dynamic signature of a running process. nil if the process is gone or macOS
    /// will not hand out its code object. Blocking; call off the main thread.
    package static func read(pid: Int32) -> CodeSignature? {
        var code: SecCode?
        let attributes = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else {
            return nil
        }
        var error: Unmanaged<CFError>?
        let validity = SecCodeCheckValidityWithErrors(code, [], nil, &error)
        let notarized = notarizedRequirement.map { SecCodeCheckValidity(code, [], $0) == errSecSuccess }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
            return CodeSignature(identifier: nil, teamIdentifier: nil, leafSubject: nil, leafKind: .none,
                                 isValid: false, validityError: "no static code", isAdHoc: false,
                                 hardenedRuntime: false, linkerSigned: false, cdHash: nil,
                                 designatedRequirement: nil, notarized: nil)
        }
        return build(staticCode, validity: validity, error: error, notarized: notarized)
    }

    /// Read the signature of code on disk — an app bundle or a bare executable. Resources are
    /// not re-hashed (a multi-gigabyte bundle would take seconds); the executable is.
    package static func read(path: String) -> CodeSignature? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        let flags = SecCSFlags(rawValue: kSecCSDoNotValidateResources)
        var error: Unmanaged<CFError>?
        let validity = SecStaticCodeCheckValidityWithErrors(staticCode, flags, nil, &error)
        let notarized = notarizedRequirement.map { SecStaticCodeCheckValidity(staticCode, flags, $0) == errSecSuccess }
        return build(staticCode, validity: validity, error: error, notarized: notarized)
    }

    private static let notarizedRequirement: SecRequirement? = {
        var requirement: SecRequirement?
        return SecRequirementCreateWithString("notarized" as CFString, [], &requirement) == errSecSuccess ? requirement : nil
    }()

    private static func build(_ staticCode: SecStaticCode, validity: OSStatus, error: Unmanaged<CFError>?, notarized: Bool?) -> CodeSignature {
        let validityError = validity == errSecSuccess ? nil
            : (error?.takeRetainedValue().localizedDescription ?? (SecCopyErrorMessageString(validity, nil) as String?) ?? "OSStatus \(validity)")
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation)
        SecCodeCopySigningInformation(staticCode, flags, &info)
        let dict = (info as? [String: Any]) ?? [:]

        let certificates = dict[kSecCodeInfoCertificates as String] as? [SecCertificate]
        let leafSubject = certificates?.first.flatMap { SecCertificateCopySubjectSummary($0) as String? }
        let csFlags = (dict[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let cdHash = (dict[kSecCodeInfoUnique as String] as? Data)?.map { String(format: "%02x", $0) }.joined()
        var requirementText: String?
        if let requirementObject = dict[kSecCodeInfoDesignatedRequirement as String] {
            let requirement = requirementObject as! SecRequirement
            var text: CFString?
            if SecRequirementCopyString(requirement, [], &text) == errSecSuccess { requirementText = text as String? }
        }
        return CodeSignature(
            identifier: dict[kSecCodeInfoIdentifier as String] as? String,
            teamIdentifier: dict[kSecCodeInfoTeamIdentifier as String] as? String,
            leafSubject: leafSubject,
            leafKind: LeafKind.classify(leafSubject),
            isValid: validity == errSecSuccess,
            validityError: validityError,
            isAdHoc: csFlags & flagAdHoc != 0,
            hardenedRuntime: csFlags & flagRuntime != 0,
            linkerSigned: csFlags & flagLinkerSigned != 0,
            cdHash: cdHash,
            designatedRequirement: requirementText,
            notarized: notarized
        )
    }
}
