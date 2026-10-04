import Crypto
import Foundation
import SwiftASN1
import X509

/// Pelican's own certificate authority, built so that even if it is stolen it cannot be used
/// against you.
///
/// Three deliberate limits:
///
/// 1. **The root signs once and its key is destroyed.** A root is generated in memory, signs a
///    single issuing certificate, and its private key is never stored anywhere. The certificate
///    you trust therefore cannot sign anything else, ever — not by Pelican, and not by anyone
///    who takes a copy of this Mac.
/// 2. **The issuing certificate is name-constrained.** It carries the list of AI service domains
///    the catalog knows, and excludes every IP address. A conformant client will refuse a
///    certificate from it for any other name, so a stolen issuing key cannot impersonate your
///    bank. Constraints are put on the *intermediate*, not the root, because clients are
///    required to enforce them there.
/// 3. **Leaves are short-lived and never written down.** Each is minted in memory for one host,
///    valid for two days.
///
/// Adding a domain means a new root and one more trust prompt: the set a certificate can vouch
/// for is fixed when you trust it, which is the point.
package struct LocalAuthority: Sendable {

    /// The certificate a person is asked to trust. Its key no longer exists.
    package let root: Certificate
    /// The certificate that actually signs leaves, sent alongside each one.
    package let issuing: Certificate
    package let issuingKey: Certificate.PrivateKey
    /// The domains this authority may vouch for, as name constraints.
    package let permittedDomains: [String]

    package static let rootLifetime: TimeInterval = 365 * 24 * 60 * 60
    package static let leafLifetime: TimeInterval = 48 * 60 * 60
    /// Backdated a little, so a client whose clock is slightly behind still accepts a new leaf.
    package static let leafBackdate: TimeInterval = 60 * 60

    /// Build a new authority. `permittedDomains` are domain suffixes — "anthropic.com" permits
    /// "api.anthropic.com" and nothing else outside the list.
    package init(permittedDomains: [String], now: Date = Date()) throws {
        let domains = permittedDomains
            .map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". ")) }
            .filter { !$0.isEmpty }
            .sorted()
        precondition(!domains.isEmpty, "an authority that may vouch for nothing is not useful")
        self.permittedDomains = domains

        // The root exists only for the length of this initializer.
        let rootKey = Certificate.PrivateKey(P256.Signing.PrivateKey())
        let rootName = try DistinguishedName {
            CommonName("Pelican local CA")
            OrganizationName("Pelican — this Mac only")
        }
        let notBefore = now.addingTimeInterval(-Self.leafBackdate)
        let notAfter = now.addingTimeInterval(Self.rootLifetime)

        root = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: rootKey.publicKey,
            notValidBefore: notBefore,
            notValidAfter: notAfter,
            issuer: rootName,
            subject: rootName,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: 1))
                Critical(KeyUsage(keyCertSign: true, cRLSign: true))
            },
            issuerPrivateKey: rootKey)

        let issuingKey = Certificate.PrivateKey(P256.Signing.PrivateKey())
        let issuingName = try DistinguishedName {
            CommonName("Pelican inspection")
            OrganizationName("Pelican — this Mac only")
        }
        issuing = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: issuingKey.publicKey,
            notValidBefore: notBefore,
            notValidAfter: notAfter,
            issuer: rootName,
            subject: issuingName,
            extensions: try Certificate.Extensions {
                // pathLength 0: it may issue leaves, never another authority.
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: 0))
                Critical(KeyUsage(keyCertSign: true, cRLSign: true))
                // Server certificates only, for these names only, and never for a bare address.
                try ExtendedKeyUsage([.serverAuth])
                Critical(NameConstraints(
                    permittedDNSDomains: domains,
                    excludedIPRanges: [Self.allIPv4, Self.allIPv6]))
            },
            issuerPrivateKey: rootKey)
        self.issuingKey = issuingKey
        // rootKey goes out of scope here and is never persisted.
    }

    /// Whether this authority is allowed to vouch for a host at all. Checked before minting,
    /// so Pelican refuses rather than producing a certificate a client will reject.
    package func permits(_ host: String) -> Bool {
        let name = host.lowercased()
        return permittedDomains.contains { name == $0 || name.hasSuffix("." + $0) }
    }

    /// A certificate for one host, valid briefly, carrying the names the real server offered
    /// that this authority is allowed to vouch for.
    ///
    /// `upstreamNames` are the real server's subject alternative names. Mirroring them keeps a
    /// client that checks for a particular name happy, and intersecting them with what is
    /// permitted means the constraint is never exceeded.
    package func leaf(for host: String, upstreamNames: [String] = [], now: Date = Date())
        throws -> (certificate: Certificate, key: Certificate.PrivateKey) {
        guard permits(host) else { throw LocalAuthorityError.hostNotPermitted(host) }

        var names = [host]
        for name in upstreamNames where permits(name) && !names.contains(name) {
            names.append(name)
        }

        let key = Certificate.PrivateKey(P256.Signing.PrivateKey())
        let subject = try DistinguishedName { CommonName(host) }
        let certificate = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: key.publicKey,
            notValidBefore: now.addingTimeInterval(-Self.leafBackdate),
            notValidAfter: now.addingTimeInterval(Self.leafLifetime),
            issuer: issuing.subject,
            subject: subject,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                Critical(KeyUsage(digitalSignature: true, keyEncipherment: true))
                try ExtendedKeyUsage([.serverAuth])
                SubjectAlternativeNames(names.map { .dnsName($0) })
            },
            issuerPrivateKey: issuingKey)
        return (certificate, key)
    }

    /// The chain a client is sent: the leaf, then the authority that signed it.
    package func chain(for leaf: Certificate) -> [Certificate] { [leaf, issuing] }

    /// Every IPv4 and IPv6 address, as an excluded constraint: this authority may never vouch
    /// for a bare address.
    private static let allIPv4 = ASN1OctetString(contentBytes: [0, 0, 0, 0, 0, 0, 0, 0][...])
    private static let allIPv6 = ASN1OctetString(
        contentBytes: ArraySlice([UInt8](repeating: 0, count: 32)))
}

package enum LocalAuthorityError: Error, Equatable, CustomStringConvertible {
    /// Asked to vouch for a name outside what the user trusted it for.
    case hostNotPermitted(String)

    package var description: String {
        switch self {
        case .hostNotPermitted(let host):
            return "Pelican's certificate authority is not allowed to vouch for \(host); it can only "
                + "issue for the AI services you turned inspection on for."
        }
    }
}
