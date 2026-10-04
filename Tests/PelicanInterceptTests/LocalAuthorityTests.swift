import Crypto
import Foundation
import Testing
import X509
@testable import PelicanIntercept

@Suite struct LocalAuthorityTests {

    private let domains = ["anthropic.com", "claude.ai", "cursor.sh"]

    private func authority() throws -> LocalAuthority {
        try LocalAuthority(permittedDomains: domains)
    }

    @Test func theRootSignsTheIssuerAndIsAnAuthority() throws {
        let ca = try authority()
        #expect(ca.root.subject == ca.root.issuer)                 // self-signed
        #expect(ca.issuing.issuer == ca.root.subject)              // signed by the root
        let basic = try #require(try ca.root.extensions.basicConstraints)
        #expect(basic == .isCertificateAuthority(maxPathLength: 1))
        // The issuer may sign leaves but never another authority.
        #expect(try ca.issuing.extensions.basicConstraints == .isCertificateAuthority(maxPathLength: 0))
    }

    @Test func theIssuerCarriesTheNameConstraintsAndExcludesAddresses() throws {
        let ca = try authority()
        let constraints = try #require(try ca.issuing.extensions.nameConstraints)
        let permitted = constraints.permittedDNSDomains.map { $0 }
        #expect(Set(permitted) == Set(domains))
        // Excluding every address means it can never vouch for a bare IP.
        #expect(!constraints.excludedIPRanges.isEmpty)
    }

    @Test func aLeafIsIssuedForAPermittedHost() throws {
        let ca = try authority()
        let (leaf, _) = try ca.leaf(for: "api.anthropic.com")
        #expect(leaf.issuer == ca.issuing.subject)
        let names = try #require(try leaf.extensions.subjectAlternativeNames)
        #expect(names.contains { if case .dnsName(let n) = $0 { return n == "api.anthropic.com" }; return false })
        #expect(try leaf.extensions.basicConstraints == .notCertificateAuthority)
        #expect(ca.chain(for: leaf).count == 2)
    }

    @Test func mintingForAnythingElseIsRefusedOutright() throws {
        let ca = try authority()
        for host in ["bank.example.com", "login.microsoftonline.com", "notanthropic.com", "1.2.3.4"] {
            #expect(!ca.permits(host), "\(host) should not be permitted")
            #expect(throws: LocalAuthorityError.hostNotPermitted(host)) {
                _ = try ca.leaf(for: host)
            }
        }
    }

    @Test func suffixMatchingDoesNotLeakToLookalikeDomains() throws {
        let ca = try authority()
        #expect(ca.permits("anthropic.com"))
        #expect(ca.permits("api.anthropic.com"))
        #expect(ca.permits("a.b.anthropic.com"))
        // The classic mistake: a suffix check that matches an attacker's domain.
        #expect(!ca.permits("evil-anthropic.com"))
        #expect(!ca.permits("anthropic.com.evil.net"))
    }

    @Test func upstreamNamesAreMirroredOnlyWhereTheyArePermitted() throws {
        let ca = try authority()
        let (leaf, _) = try ca.leaf(
            for: "api.anthropic.com",
            upstreamNames: ["api.anthropic.com", "claude.ai", "cdn.example.net"])
        let names = try #require(try leaf.extensions.subjectAlternativeNames).compactMap { name -> String? in
            if case .dnsName(let value) = name { return value }
            return nil
        }
        #expect(names.contains("api.anthropic.com"))
        #expect(names.contains("claude.ai"))
        // A name outside the constraint is dropped rather than exceeding what was trusted.
        #expect(!names.contains("cdn.example.net"))
    }

    @Test func aVerifierAcceptsAPermittedChainAndRejectsAConstraintBreach() async throws {
        let ca = try authority()
        let (good, _) = try ca.leaf(for: "api.anthropic.com")

        var verifier = Verifier(rootCertificates: CertificateStore([ca.root])) {
            RFC5280Policy(validationTime: Date())
        }
        let accepted = await verifier.validate(leafCertificate: good, intermediates: CertificateStore([ca.issuing]))
        guard case .validCertificate = accepted else {
            Issue.record("a permitted leaf should verify: \(accepted)"); return
        }

        // Forge a leaf for a name outside the constraint, signed with the real issuing key —
        // exactly what a stolen key could attempt. The constraint must stop it.
        let forgedKey = Certificate.PrivateKey(P256.Signing.PrivateKey())
        let forged = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: forgedKey.publicKey,
            notValidBefore: Date().addingTimeInterval(-60),
            notValidAfter: Date().addingTimeInterval(3600),
            issuer: ca.issuing.subject,
            subject: try DistinguishedName { CommonName("bank.example.com") },
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                SubjectAlternativeNames([.dnsName("bank.example.com")])
            },
            issuerPrivateKey: ca.issuingKey)

        var strict = Verifier(rootCertificates: CertificateStore([ca.root])) {
            RFC5280Policy(validationTime: Date())
        }
        let rejected = await strict.validate(leafCertificate: forged, intermediates: CertificateStore([ca.issuing]))
        guard case .couldNotValidate = rejected else {
            Issue.record("a name outside the constraint must not verify, got \(rejected)"); return
        }
    }

    @Test func leavesAreShortLivedAndBackdated() throws {
        let now = Date()
        let ca = try LocalAuthority(permittedDomains: domains, now: now)
        let (leaf, _) = try ca.leaf(for: "api.anthropic.com", now: now)
        #expect(leaf.notValidBefore < now)                              // tolerates a slow clock
        #expect(leaf.notValidAfter.timeIntervalSince(now) <= LocalAuthority.leafLifetime + 1)
        #expect(leaf.notValidAfter > now)
    }

    @Test func eachAuthorityIsItsOwn() throws {
        let a = try authority(), b = try authority()
        #expect(a.root.serialNumber != b.root.serialNumber)
        #expect(a.issuing.publicKey != b.issuing.publicKey)
    }
}
