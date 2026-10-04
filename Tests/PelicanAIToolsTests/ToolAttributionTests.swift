import Foundation
import Testing
@testable import PelicanAITools
@testable import PelicanKit

// MARK: - Fixtures
//
// Built from what `codesign`, `ps` and Pelican's own probes reported on a Mac on 2026-10-04.

private var clock: UInt64 = 1_700_000_000_000_000

private func stamp(_ pid: Int32) -> ProcessStamp {
    clock += 1_000_000
    return ProcessStamp(pid: pid, startTime: clock)
}

private func signature(identifier: String?, team: String?, valid: Bool = true,
                       leaf: String? = nil) -> CodeSignature {
    CodeSignature(identifier: identifier, teamIdentifier: team,
                  leafSubject: leaf ?? team.map { "Developer ID Application: Example (\($0))" },
                  leafKind: team == nil ? .none : .developerID, isValid: valid, validityError: nil,
                  isAdHoc: team == nil, hardenedRuntime: true, linkerSigned: false,
                  cdHash: "abc", designatedRequirement: nil, notarized: true)
}

private func facts(_ name: String, pid: Int32 = 100, path: String? = nil, outer: String? = nil,
                   identifier: String? = nil, team: String? = nil, adHoc: Bool = false,
                   arguments: [String]? = nil) -> ProcessFacts {
    ProcessFacts(
        node: ProcessNode(stamp: stamp(pid), name: name, executablePath: path,
                          outerBundleID: outer, firstSeen: Date()),
        signature: adHoc ? signature(identifier: identifier, team: nil)
                         : (identifier == nil && team == nil ? nil : signature(identifier: identifier, team: team)),
        arguments: arguments)
}

/// Claude Code's native binary, as the VS Code extension ships it.
private func claudeCode() -> ProcessFacts {
    facts("claude", pid: 16186,
          path: NSString(string: "~/.vscode/extensions/anthropic.claude-code-2.1.289-darwin-arm64/resources/native-binary/claude").expandingTildeInPath,
          identifier: "com.anthropic.claude-code", team: "Q6L2SF6YDW")
}
private func codeHelperPlugin() -> ProcessFacts {
    facts("Code Helper (Plugin)", pid: 15708,
          path: "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)",
          outer: "com.microsoft.VSCode", identifier: "com.microsoft.VSCode.helper", team: "UBF8T346G9")
}
private func vsCode() -> ProcessFacts {
    facts("Code", pid: 2322, path: "/Applications/Visual Studio Code.app/Contents/MacOS/Code",
          outer: "com.microsoft.VSCode", identifier: "com.microsoft.VSCode", team: "UBF8T346G9")
}

// MARK: - Tests

@Suite struct ToolAttributionTests {

    @Test func claudeCodeIsRecognisedBySignatureAndNamesItsHost() throws {
        let chain = [claudeCode(), codeHelperPlugin(), vsCode()]
        let result = try #require(ToolAttributor.attribute(chain: chain))
        #expect(result.toolID == "claude")
        #expect(result.surfaceID == "claude-code")
        #expect(result.origin == .tool)
        #expect(result.basis == .signature)
        #expect(result.evidence.contains("com.anthropic.claude-code"))
        // The tool wins over the app it runs inside, which is recorded beside it.
        #expect(result.hostAppName == "Visual Studio Code")
    }

    @Test func aCommandTheAgentRunsIsTheAgentsTraffic() throws {
        let chain = [facts("curl", pid: 70521, path: "/usr/bin/curl"),
                     facts("zsh", pid: 70489, path: "/bin/zsh"),
                     claudeCode(), codeHelperPlugin(), vsCode()]
        let result = try #require(ToolAttributor.attribute(chain: chain))
        #expect(result.toolID == "claude")
        #expect(result.basis == .lineage)
        #expect(result.origin == .subprocess("curl"))
        #expect(result.chainDisplay.hasPrefix("curl ← zsh ← claude"))
        #expect(result.evidence.contains("Claude Code started it"))
    }

    @Test func cursorsBundledNodeBelongsToCursorThoughAnotherTeamSignedIt() throws {
        // Observed: Cursor ships node signed by the Node.js Foundation, not Anysphere.
        let node = facts("node", pid: 900,
                         path: "/Applications/Cursor.app/Contents/Resources/app/resources/helpers/node",
                         outer: "com.todesktop.230313mzl4w4u92",
                         identifier: "node", team: "HX7739G8FX")
        let result = try #require(ToolAttributor.attribute(chain: [node]))
        #expect(result.toolID == "cursor")
        #expect(result.basis == .bundle)
    }

    @Test func cursorsGenericElectronHelperIsStillCursors() throws {
        // Observed: three of Cursor's four helpers report com.github.Electron.helper, so only
        // the outermost bundle identifies them.
        let helper = facts("Cursor Helper (Renderer)", pid: 901,
                           path: "/Applications/Cursor.app/Contents/Frameworks/Cursor Helper (Renderer).app/Contents/MacOS/Cursor Helper (Renderer)",
                           outer: "com.todesktop.230313mzl4w4u92",
                           identifier: "com.github.Electron.helper", team: "VDXQ22DGB9")
        let result = try #require(ToolAttributor.attribute(chain: [helper]))
        #expect(result.toolID == "cursor")
    }

    @Test func anotherVendorsElectronHelperIsNotCursors() {
        let stranger = facts("Some Helper", pid: 902,
                             path: "/Applications/Stranger.app/Contents/Frameworks/Some Helper.app/Contents/MacOS/Some Helper",
                             outer: "com.example.stranger",
                             identifier: "com.github.Electron.helper", team: "ZZZZZZZZZZ")
        #expect(ToolAttributor.attribute(chain: [stranger]) == nil)
    }

    @Test func applesCursorUIViewServiceIsNotCursor() {
        // macOS ships this. Name-matching on "Cursor" would claim it.
        let apple = facts("CursorUIViewService", pid: 861,
                          path: "/System/Library/PrivateFrameworks/TextInputUIMacHelper.framework/Versions/A/XPCServices/CursorUIViewService.xpc/Contents/MacOS/CursorUIViewService",
                          identifier: "com.apple.TextInputUI.xpc.CursorUIViewService", team: nil)
        #expect(ToolAttributor.attribute(chain: [apple]) == nil)
    }

    @Test func anImpostorAtTheRightPathIsFlaggedNotTrusted() throws {
        // Something ad-hoc signed sitting where Claude Code installs: matched by path, at a
        // weaker basis than a signature, and the evidence says so.
        let impostor = facts("claude", pid: 500,
                             path: NSString(string: "~/.local/bin/claude").expandingTildeInPath,
                             identifier: "claude", team: nil, adHoc: true)
        let result = try #require(ToolAttributor.attribute(chain: [impostor]))
        #expect(result.basis == .path)
        #expect(result.basis < .signature)
    }

    @Test func aBinaryAtTheRightPathSignedByAnotherTeamSaysSo() throws {
        let odd = facts("claude", pid: 501,
                        path: NSString(string: "~/.local/bin/claude").expandingTildeInPath,
                        identifier: "com.anthropic.claude-code", team: "ZZZZZZZZZZ")
        let result = try #require(ToolAttributor.attribute(chain: [odd]))
        // The signature matcher requires Anthropic's team, so it falls to the path, noting who signed.
        #expect(result.basis == .path)
        #expect(result.evidence.contains("ZZZZZZZZZZ"))
    }

    @Test func toolsAwaitingAFingerprintAttributeNothing() {
        let codexish = facts("codex", pid: 600, path: "/opt/homebrew/bin/codex",
                             identifier: "com.openai.codex", team: "AAAAAAAAAA")
        // Codex's matchers are all unverified, so nothing attributes to it yet.
        #expect(ToolAttributor.attribute(chain: [codexish]) == nil)
        #expect(AITool.codex.awaitingFingerprint)
        #expect(AITool.muse.awaitingFingerprint)
        #expect(!AITool.claude.awaitingFingerprint)
        #expect(!AITool.cursor.awaitingFingerprint)
    }

    @Test func theNearestToolInTheChainWins() throws {
        // Claude Code running inside Cursor: the traffic is Claude Code's.
        let chain = [claudeCode(),
                     facts("Cursor Helper (Plugin)", pid: 950,
                           path: "/Applications/Cursor.app/Contents/Frameworks/Cursor Helper (Plugin).app/Contents/MacOS/Cursor Helper (Plugin)",
                           outer: "com.todesktop.230313mzl4w4u92", identifier: "com.github.Electron.helper", team: "VDXQ22DGB9")]
        let result = try #require(ToolAttributor.attribute(chain: chain))
        #expect(result.toolID == "claude")
        #expect(result.hostAppName == "Cursor")
    }

    @Test func anMCPServerIsNamedRatherThanCalledASubprocess() throws {
        let server = MCPServerRef(toolID: "claude", name: "github", command: "npx",
                                  marker: "@modelcontextprotocol/server-github")
        let chain = [facts("npx", pid: 700, path: "/opt/homebrew/bin/npx",
                           arguments: ["npx", "-y", "@modelcontextprotocol/server-github"]),
                     claudeCode()]
        let result = try #require(ToolAttributor.attribute(chain: chain, mcpServers: [server]))
        #expect(result.origin == .mcpServer("github"))
        #expect(result.basis == .lineage)
    }

    @Test func destinationOnlyIsTheWeakestAndSaysSo() {
        let result = ToolAttributor.attributeByDestination(
            tool: .claude, host: "api.anthropic.com", processName: "Code Helper (Plugin)",
            chain: ["Code Helper (Plugin)", "Code"])
        #expect(result.basis == .destination)
        #expect(result.basis < .lineage)
        #expect(result.evidence.contains("cannot tell which process"))
    }
}

@Suite struct CatalogTests {

    @Test func everyToolIsSelfConsistent() throws {
        for tool in AITool.all {
            #expect(!tool.surfaces.isEmpty, "\(tool.name) has no surfaces")
            #expect(Set(tool.surfaces.map(\.id)).count == tool.surfaces.count, "\(tool.name) has duplicate surface ids")
            for rule in tool.hosts {
                // Anything we forward-resolve must be a concrete name, not a wildcard.
                for name in rule.resolve {
                    #expect(!name.hasPrefix("*"), "\(tool.name): cannot resolve the pattern \(name)")
                    #expect(rule.pattern.matches(name), "\(tool.name): \(name) does not match its own rule")
                }
            }
        }
        #expect(Set(AITool.all.map(\.id)).count == AITool.all.count)
    }

    @Test func observedFactsCarryADate() {
        for tool in AITool.all {
            for surface in tool.surfaces {
                for matcher in surface.matchers {
                    if case .observed(let day, _) = matcher.verification {
                        #expect(day.count == 10, "\(tool.name): \(day) is not a yyyy-mm-dd date")
                    }
                }
            }
        }
    }

    @Test func sharedHostsAreNeverTreatedAsAVendorsOwn() {
        // These belong to infrastructure every customer shares, so an address alone must never
        // attribute a flow to a tool.
        let shared = ["registry.npmjs.org", "github.com", "raw.githubusercontent.com",
                      "storage.googleapis.com", "formulae.brew.sh",
                      "http-intake.logs.us5.datadoghq.com", "browser-intake-us5-datadoghq.com"]
        for tool in AITool.all {
            for rule in tool.hosts where rule.dedicated {
                for host in shared {
                    #expect(!rule.pattern.matches(host),
                            "\(tool.name) claims the shared host \(host) as its own")
                }
            }
        }
    }

    @Test func claudesTelemetryClaimIsRecordedForChecking() throws {
        let rule = try #require(AITool.claude.hosts.first { $0.purpose == .telemetry })
        #expect(rule.pattern.matches("http-intake.logs.us5.datadoghq.com"))
        #expect(!rule.dedicated)
        #expect(rule.claims.contains { $0.contains("never include your code, prompts, or file paths") })
    }

    @Test func hostRulesMatchTheRightWay() {
        let anthropic = AITool.claude
        #expect(anthropic.rule(matching: ["api.anthropic.com"])?.rule.purpose == .inference)
        #expect(anthropic.rule(matching: ["evil-api.anthropic.com.attacker.net"]) == nil)
        let cursor = AITool.cursor
        #expect(cursor.rule(matching: ["api2.cursor.sh"])?.rule.purpose == .inference)
        #expect(cursor.rule(matching: ["repo42.cursor.sh"])?.rule.purpose == .code)
        // A suffix rule matches the domain itself and anything under it, and nothing else.
        #expect(HostPattern.suffix("cursor.sh").matches("cursor.sh"))
        #expect(HostPattern.suffix("cursor.sh").matches("api2.cursor.sh"))
        #expect(!HostPattern.suffix("cursor.sh").matches("notcursor.sh"))
    }
}
