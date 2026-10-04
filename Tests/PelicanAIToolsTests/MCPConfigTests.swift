import Foundation
import Testing
@testable import PelicanAITools

@Suite struct MCPConfigTests {

    private func json(_ text: String) -> [MCPServerRef] {
        MCPConfigReader.parse(Data(text.utf8), format: .claudeJSON, toolID: "claude")
    }
    private func toml(_ text: String) -> [MCPServerRef] {
        MCPConfigReader.parse(Data(text.utf8), format: .codexTOML, toolID: "codex")
    }

    @Test func readsServersFromAClaudeConfig() throws {
        let servers = json("""
        {"mcpServers": {
          "github": {"command": "npx", "args": ["-y", "@modelcontextprotocol/server-github"],
                     "env": {"GITHUB_TOKEN": "ghp_supersecretvalue"}},
          "notes":  {"command": "/opt/homebrew/bin/uvx", "args": ["notes-mcp"]}
        }}
        """)
        #expect(servers.count == 2)
        let github = try #require(servers.first { $0.name == "github" })
        #expect(github.command == "npx")
        #expect(github.marker == "@modelcontextprotocol/server-github")
        // The command's basename, not the path it was written with.
        #expect(servers.first { $0.name == "notes" }?.command == "uvx")
    }

    @Test func projectScopedServersAreFound() throws {
        let servers = json("""
        {"projects": {"/somewhere/repo": {"mcpServers": {
          "local": {"command": "node", "args": ["./server.js"]}}}}}
        """)
        #expect(servers.map(\.name) == ["local"])
        #expect(servers[0].marker == "./server.js")
    }

    @Test func remoteServersKeepOnlyTheirHost() throws {
        let servers = json("""
        {"mcpServers": {"remote": {"url": "https://mcp.example.com/sse?token=abc123secret"}}}
        """)
        let remote = try #require(servers.first)
        #expect(remote.host == "mcp.example.com")
        #expect(!describe(servers).contains("abc123secret"))
    }

    @Test func codexSubTablesAreNotMistakenForServers() throws {
        // Observed shape: `[mcp_servers.<name>]` followed by `[mcp_servers.<name>.env]`.
        let servers = toml("""
        [mcp_servers.node_repl]
        command = "node"
        args = ["node_repl.js"]

        [mcp_servers.node_repl.env]
        API_TOKEN = "sk-live-not-a-real-token"

        [mcp_servers.other]
        command = "uvx"
        args = ["other-mcp"]
        """)
        #expect(servers.map(\.name).sorted() == ["node_repl", "other"])
        #expect(!describe(servers).contains("sk-live-not-a-real-token"))
    }

    @Test func nothingSecretSurvivesTheRead() {
        let secrets = ["ghp_supersecretvalue", "sk-live-not-a-real-token", "abc123secret", "hunter2"]
        let all = json("""
        {"mcpServers": {"a": {"command": "npx", "args": ["-y", "pkg", "--token", "hunter2"],
                              "env": {"X": "ghp_supersecretvalue"},
                              "headers": {"Authorization": "Bearer abc123secret"}}}}
        """) + toml("""
        [mcp_servers.b]
        command = "node"
        env = { TOKEN = "sk-live-not-a-real-token" }
        """)
        let text = describe(all)
        for secret in secrets {
            #expect(!text.contains(secret), "a secret survived: \(secret)")
        }
    }

    @Test func malformedInputIsIgnoredRatherThanFatal() {
        #expect(json("not json at all").isEmpty)
        #expect(json("{}").isEmpty)
        #expect(json("{\"mcpServers\": []}").isEmpty)
        #expect(toml("[[[").isEmpty)
        #expect(toml("").isEmpty)
    }

    /// Everything a server ref could possibly carry, as one string.
    private func describe(_ servers: [MCPServerRef]) -> String {
        servers.map { "\($0.toolID)|\($0.name)|\($0.command)|\($0.marker ?? "")|\($0.host ?? "")" }
            .joined(separator: "\n")
    }
}
