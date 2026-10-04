import Foundation
import PelicanKit

// What Pelican knows about other vendors' AI tools. Every value here is a product fact: an
// identifier a vendor signs with, a path it installs to, a host it publishes. Third-party team
// identifiers are product facts too — they are what macOS reports and what a vendor publishes,
// and showing them is how a user checks a process is really the vendor's. Nothing about Rao's
// own signing identity or this Mac appears here.
//
// Each fact carries how it is known. `--ai-probe` prints a paste-ready entry, so an unverified
// one can be confirmed on any machine and upgraded to `.observed`.

extension AITool {
    package static let all: [AITool] = [.claude, .codex, .cursor, .muse]

    package static func with(id: String) -> AITool? { all.first { $0.id == id } }

    /// Hostnames worth resolving for every tool in the catalog.
    package static var allHostnamesToResolve: [String] {
        Array(Set(all.flatMap(\.hostnamesToResolve))).sorted()
    }
}

// MARK: - Anthropic

private let observedHere = Verification.observed(on: "2026-10-04", version: nil)
private let anthropicDocs = Verification.documented("Anthropic's network configuration docs")
private let cursorDocs = Verification.documented("Cursor's network configuration docs")

extension AITool {
    static let claude = AITool(
        id: "claude",
        name: "Claude",
        vendor: "Anthropic",
        siteURL: URL(string: "https://claude.com")!,
        teams: ["Q6L2SF6YDW"],
        surfaces: [
            ToolSurface(
                id: "claude-code",
                name: "Claude Code",
                kind: .cli,
                matchers: [
                    ProcessMatcher(.signingIdentifier("com.anthropic.claude-code"),
                                   verification: .observed(on: "2026-10-04", version: "2.1.289")),
                    // The VS Code / Cursor extension ships its own binary.
                    ProcessMatcher(.path("~/.vscode/extensions/anthropic.claude-code-*/resources/native-binary/claude"),
                                   verification: .observed(on: "2026-10-04", version: "2.1.289")),
                    ProcessMatcher(.path("~/.cursor/extensions/anthropic.claude-code-*/resources/native-binary/claude"),
                                   verification: .documented("the extension installs the same way in Cursor")),
                    ProcessMatcher(.path("~/.local/bin/claude"),
                                   verification: .documented("Claude Code's native installer")),
                    ProcessMatcher(.path("~/.claude/local/claude"),
                                   verification: .documented("Claude Code's local install")),
                ],
                // Every flow seen from it on this Mac was a kernel socket.
                networking: .kernelSockets,
                agents: ["claude-cli"]),
            ToolSurface(
                id: "claude-desktop",
                name: "Claude",
                kind: .desktopApp,
                matchers: [
                    ProcessMatcher(.outerBundle("com.anthropic.claudefordesktop"),
                                   verification: .unverified),
                ],
                networking: .unknown),
        ],
        hosts: [
            HostRule(.exact("api.anthropic.com"), purpose: .inference,
                     note: "the model: prompts and replies. Also feature flags, telemetry events, and WebFetch's domain safety check.",
                     resolve: ["api.anthropic.com"], dedicated: true,
                     claims: ["The WebFetch domain check sends \"only the hostname … not the full URL, path, or page contents\"."],
                     verification: .observed(on: "2026-10-04", version: nil)),
            HostRule(.exact("claude.ai"), purpose: .auth, note: "claude.ai account sign-in.",
                     resolve: ["claude.ai"], dedicated: true, verification: anthropicDocs),
            HostRule(.exact("platform.claude.com"), purpose: .auth,
                     note: "Console sign-in, and OAuth token exchange, refresh and revocation.",
                     resolve: ["platform.claude.com"], dedicated: true, verification: anthropicDocs),
            HostRule(.exact("claude.com"), purpose: .auth, note: "sign-in opens here, then redirects to claude.ai.",
                     resolve: ["claude.com"], dedicated: true, verification: anthropicDocs),
            HostRule(.exact("mcp-proxy.anthropic.com"), purpose: .mcp,
                     note: "MCP connectors configured on claude.ai are reached through this proxy.",
                     resolve: ["mcp-proxy.anthropic.com"], dedicated: true,
                     verification: .observed(on: "2026-10-04", version: nil)),
            HostRule(.exact("downloads.claude.ai"), purpose: .update,
                     note: "the updater, and plugin downloads.", resolve: ["downloads.claude.ai"],
                     verification: anthropicDocs),
            HostRule(.exact("code.claude.com"), purpose: .content, note: "documentation lookups.",
                     resolve: ["code.claude.com"], verification: anthropicDocs),
            HostRule(.suffix("claudeusercontent.com"), purpose: .content,
                     note: "artifact contents, and the Claude in Chrome bridge.", verification: anthropicDocs),
            HostRule(.exact("http-intake.logs.us5.datadoghq.com"), purpose: .telemetry,
                     note: "operational telemetry, when the CLI talks to the Anthropic API directly. DISABLE_TELEMETRY=1 turns it off.",
                     resolve: ["http-intake.logs.us5.datadoghq.com"],
                     claims: ["Metrics \"never include your code, prompts, or file paths\"."],
                     verification: .observed(on: "2026-10-04", version: nil)),
            HostRule(.exact("browser-intake-us5-datadoghq.com"), purpose: .errorReporting,
                     note: "error reports. DISABLE_ERROR_REPORTING=1 turns it off.",
                     resolve: ["browser-intake-us5-datadoghq.com"],
                     claims: ["Secrets, file paths, email addresses and other personal information are redacted \"before anything leaves your machine\"."],
                     verification: anthropicDocs),
            HostRule(.exact("registry.npmjs.org"), purpose: .code,
                     note: "plugin installs and npx-launched MCP servers. Shared with every npm user.",
                     verification: anthropicDocs),
            HostRule(.exact("github.com"), purpose: .code,
                     note: "cloning plugin marketplaces. Shared with every GitHub user.", verification: anthropicDocs),
            HostRule(.exact("raw.githubusercontent.com"), purpose: .content,
                     note: "the release-notes feed. Shared.", verification: anthropicDocs),
            HostRule(.exact("storage.googleapis.com"), purpose: .content,
                     note: "plugin metadata. Shared with every Google Cloud Storage user.", verification: anthropicDocs),
            HostRule(.exact("formulae.brew.sh"), purpose: .update,
                     note: "version checks on Homebrew installs. Shared.", verification: anthropicDocs),
        ],
        mcpConfigs: [
            MCPConfigLocation(path: "~/.claude.json", format: .claudeJSON),
            MCPConfigLocation(path: ".mcp.json", format: .claudeJSON, projectScoped: true),
            MCPConfigLocation(path: "~/Library/Application Support/Claude/claude_desktop_config.json",
                              format: .claudeJSON),
        ])
}

// MARK: - OpenAI

extension AITool {
    static let codex = AITool(
        id: "codex",
        name: "Codex",
        vendor: "OpenAI",
        siteURL: URL(string: "https://openai.com")!,
        teams: [],
        surfaces: [
            ToolSurface(
                id: "codex-cli",
                name: "Codex CLI",
                kind: .cli,
                matchers: [
                    ProcessMatcher(.path("~/.codex/bin/codex"), verification: .unverified),
                    ProcessMatcher(.path("/opt/homebrew/bin/codex"), verification: .unverified),
                    ProcessMatcher(.path("~/.local/bin/codex"), verification: .unverified),
                ],
                networking: .unknown),
            ToolSurface(
                id: "chatgpt-desktop",
                name: "ChatGPT",
                kind: .desktopApp,
                matchers: [ProcessMatcher(.outerBundle("com.openai.chat"), verification: .unverified)],
                networking: .unknown),
        ],
        hosts: [
            HostRule(.exact("api.openai.com"), purpose: .inference, note: "the model: prompts and replies.",
                     resolve: ["api.openai.com"], verification: .documented("OpenAI's API documentation")),
            HostRule(.exact("chatgpt.com"), purpose: .inference,
                     note: "Codex requests made with a ChatGPT sign-in.", resolve: ["chatgpt.com"],
                     verification: .documented("Codex CLI documentation")),
            HostRule(.exact("auth.openai.com"), purpose: .auth, note: "sign-in.",
                     resolve: ["auth.openai.com"], verification: .documented("Codex CLI documentation")),
        ],
        mcpConfigs: [MCPConfigLocation(path: "~/.codex/config.toml", format: .codexTOML)])
}

// MARK: - Anysphere

extension AITool {
    static let cursor = AITool(
        id: "cursor",
        name: "Cursor",
        vendor: "Anysphere",
        siteURL: URL(string: "https://cursor.com")!,
        teams: ["VDXQ22DGB9"],
        surfaces: [
            ToolSurface(
                id: "cursor-app",
                name: "Cursor",
                kind: .desktopApp,
                matchers: [
                    // Three of its four helpers report the generic Electron bundle id, so the
                    // outermost app is what identifies them — including its bundled `node`,
                    // which the Node.js Foundation signs, not Anysphere.
                    ProcessMatcher(.outerBundle("com.todesktop.230313mzl4w4u92"),
                                   verification: .observed(on: "2026-10-04", version: "3.19.13")),
                    ProcessMatcher(.signingIdentifierPrefix("com.todesktop.230313mzl4w4u92"),
                                   verification: .observed(on: "2026-10-04", version: "3.19.13")),
                    ProcessMatcher(.path("/Applications/Cursor.app/*"),
                                   verification: .observed(on: "2026-10-04", version: "3.19.13")),
                ],
                networking: .unknown),
            ToolSurface(
                id: "cursor-agent",
                name: "Cursor Agent CLI",
                kind: .cli,
                matchers: [ProcessMatcher(.path("~/.local/bin/cursor-agent"), verification: .unverified)],
                networking: .unknown),
        ],
        hosts: [
            HostRule(.exact("api2.cursor.sh"), purpose: .inference, note: "most API requests.",
                     resolve: ["api2.cursor.sh"], rotating: true, verification: cursorDocs),
            HostRule(.exact("api3.cursor.sh"), purpose: .inference, note: "Cursor Tab completions.",
                     resolve: ["api3.cursor.sh"], rotating: true, verification: cursorDocs),
            HostRule(.exact("api5.cursor.sh"), purpose: .inference, note: "agent requests.",
                     resolve: ["api5.cursor.sh"], rotating: true, verification: cursorDocs),
            HostRule(.exact("repo42.cursor.sh"), purpose: .code,
                     note: "codebase search — this is where code is sent to be indexed.",
                     resolve: ["repo42.cursor.sh"], rotating: true, verification: cursorDocs),
            HostRule(.suffix("gcpp.cursor.sh"), purpose: .inference,
                     note: "Tab completions, routed by location.", rotating: true, verification: cursorDocs),
            HostRule(.exact("authenticate.cursor.sh"), purpose: .auth, note: "sign-in.",
                     resolve: ["authenticate.cursor.sh"], verification: cursorDocs),
            HostRule(.suffix("authentication.cursor.sh"), purpose: .auth, note: "token issuer.",
                     verification: cursorDocs),
            HostRule(.exact("marketplace.cursorapi.com"), purpose: .content, note: "extensions.",
                     resolve: ["marketplace.cursorapi.com"], verification: cursorDocs),
            HostRule(.suffix("cursor-cdn.com"), purpose: .update, note: "client updates.", verification: cursorDocs),
            HostRule(.suffix("cursorapi.com"), purpose: .content, note: "Cursor services.", verification: cursorDocs),
            HostRule(.suffix("cursorvm.com"), purpose: .content, note: "Cursor's cloud machines.", verification: cursorDocs),
            HostRule(.suffix("cursor.sh"), purpose: .content, note: "another Cursor service.", verification: cursorDocs),
            HostRule(.exact("downloads.cursor.com"), purpose: .update, note: "client downloads.",
                     resolve: ["downloads.cursor.com"], verification: cursorDocs),
        ],
        mcpConfigs: [
            MCPConfigLocation(path: "~/.cursor/mcp.json", format: .mcpJSON),
            MCPConfigLocation(path: ".cursor/mcp.json", format: .mcpJSON, projectScoped: true),
        ])
}

// MARK: - Meta

extension AITool {
    static let muse = AITool(
        id: "muse",
        name: "Muse",
        vendor: "Meta",
        siteURL: URL(string: "https://muse.ai")!,
        teams: [],
        surfaces: [
            ToolSurface(
                id: "muse-app",
                name: "Muse",
                kind: .desktopApp,
                matchers: [ProcessMatcher(.outerBundle("com.meta.muse"), verification: .unverified)],
                networking: .unknown),
        ],
        hosts: [
            HostRule(.suffix("muse.ai"), purpose: .inference, note: "Muse's service.", verification: .unverified),
            HostRule(.suffix("meta.ai"), purpose: .inference, note: "Meta AI's service.", verification: .unverified),
        ])
}
