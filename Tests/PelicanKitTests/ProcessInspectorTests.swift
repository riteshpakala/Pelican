import Darwin
import Foundation
import Testing
@testable import PelicanKit

@Suite struct ArgumentRedactorTests {

    private func redact(_ line: String) -> String {
        ArgumentRedactor.redact(line.split(separator: " ").map(String.init)).joined(separator: " ")
    }

    @Test func secretFlagValuesAreMasked() {
        #expect(redact("gh --token ghp_abcdefghijklmnop1234567890 repo list") == "gh --token ••• repo list")
        #expect(redact("tool --api-key=sk-live-1234567890abcdefghij --verbose") == "tool --api-key=••• --verbose")
        #expect(redact("mysql -u root -p hunter2") == "mysql -u ••• -p •••")
    }

    @Test func secretAssignmentsAndHeadersAreMasked() {
        let args = ["env", "GITHUB_TOKEN=ghp_xyz", "PATH=/usr/bin", "curl", "-H", "Authorization: Bearer abc.def.ghi"]
        let out = ArgumentRedactor.redact(args)
        #expect(out == ["env", "GITHUB_TOKEN=•••", "PATH=/usr/bin", "curl", "-H", "Authorization: •••"])
    }

    @Test func urlCredentialsAndQuerySecretsAreStripped() {
        let out = ArgumentRedactor.redact(["git", "clone", "https://alice:pw123@example.com/repo.git",
                                           "https://api.example.com/v1?api_key=XYZ&page=2"])
        #expect(!out.joined().contains("pw123"))
        #expect(!out.joined().contains("XYZ"))
        #expect(out[3].contains("page=2"))
    }

    @Test func bareHighEntropyTokensAreMasked() {
        #expect(ArgumentRedactor.looksLikeToken("sk-ant-api03-AbCdEf123456GhIjKl7890MnOp"))
        #expect(ArgumentRedactor.looksLikeToken("eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2lnbmF0dXJl"))
        #expect(redact("deploy a1B2c3D4e5F6g7H8i9J0k1L2m3N4") == "deploy •••")
    }

    @Test func ordinaryArgumentsSurvive() {
        let line = "npx -y @modelcontextprotocol/server-github --port 3000 /Users/x/projects/app README.md"
        #expect(redact(line) == line)
        #expect(redact("node /opt/codex/bin/codex.js exec --model gpt-5") == "node /opt/codex/bin/codex.js exec --model gpt-5")
    }
}

@Suite struct ProcessInspectorTests {

    @Test func outermostAppIsTheLeftmostBundle() {
        let helper = "/Applications/Cursor.app/Contents/Frameworks/Cursor Helper (Plugin).app/Contents/MacOS/Cursor Helper (Plugin)"
        #expect(LiveProcessInspector.outermostApp(of: helper) == "/Applications/Cursor.app")
        #expect(LiveProcessInspector.outermostApp(of: "/usr/bin/curl") == nil)
        // The nearest-.app reading (ProcessIdentity.enclosingApp) would give the inner helper.
        #expect(ProcessIdentity.enclosingApp(of: helper)?.hasSuffix("Cursor Helper (Plugin).app") == true)
    }

    @Test func readsThisProcess() throws {
        let inspector = LiveProcessInspector()
        let core = try #require(inspector.core(pid: getpid()))
        #expect(core.stamp.pid == getpid())
        #expect(core.parentPid == getppid())
        #expect(core.stamp.birth <= Date())
        let args = try #require(inspector.arguments(pid: getpid()))
        #expect(!args.isEmpty)
        #expect(inspector.allPids().contains(getpid()))
        #expect(inspector.children(pid: getppid()).contains(getpid()))
    }

    @Test func goneProcessesReadAsNil() {
        // pid 0 is the kernel; an absurd pid is never alive.
        #expect(LiveProcessInspector().core(pid: 999_999) == nil)
        #expect(LiveProcessInspector().arguments(pid: 999_999) == nil)
    }
}
