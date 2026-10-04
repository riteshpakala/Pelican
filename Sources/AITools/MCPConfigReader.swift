import Foundation
import PelicanKit

/// Reads the MCP server lists a tool keeps, so a process it starts can be named rather than
/// shown as an anonymous `node`.
///
/// Read-only, and deliberately forgetful: it keeps a server's name, the basename of its command
/// and one distinguishing argument, and a remote server's host. It never keeps `env`, headers,
/// or any other argument — those hold tokens. Pelican never writes these files.
package enum MCPConfigReader {

    package static func readAll(catalog: [AITool] = AITool.all,
                                home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [MCPServerRef] {
        var out: [MCPServerRef] = []
        for tool in catalog {
            for location in tool.mcpConfigs where !location.projectScoped {
                let path = location.path.hasPrefix("~/")
                    ? home.path + location.path.dropFirst(1)
                    : location.path
                guard let data = FileManager.default.contents(atPath: path) else { continue }
                out += parse(data, format: location.format, toolID: tool.id)
            }
        }
        // One entry per tool and name.
        var seen = Set<String>()
        return out.filter { seen.insert($0.id).inserted }
    }

    package static func parse(_ data: Data, format: MCPConfigLocation.Format, toolID: String) -> [MCPServerRef] {
        switch format {
        case .claudeJSON, .mcpJSON: return parseJSON(data, toolID: toolID)
        case .codexTOML: return parseTOML(data, toolID: toolID)
        }
    }

    // MARK: - JSON (Claude Code, Claude Desktop, Cursor)

    private static func parseJSON(_ data: Data, toolID: String) -> [MCPServerRef] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var out: [MCPServerRef] = []
        // Top level, and once per project entry.
        var scopes: [[String: Any]] = [root]
        if let projects = root["projects"] as? [String: Any] {
            scopes += projects.values.compactMap { $0 as? [String: Any] }
        }
        for scope in scopes {
            guard let servers = scope["mcpServers"] as? [String: Any] else { continue }
            for (name, value) in servers {
                guard let entry = value as? [String: Any] else { continue }
                out.append(server(named: name, toolID: toolID,
                                  command: entry["command"] as? String,
                                  args: entry["args"] as? [String],
                                  url: (entry["url"] ?? entry["serverUrl"]) as? String))
            }
        }
        return out
    }

    // MARK: - TOML (Codex)

    /// A deliberately small reader for `[mcp_servers.<name>]` tables: enough for `command`,
    /// `args` and `url`, and blind to everything else.
    private static func parseTOML(_ data: Data, toolID: String) -> [MCPServerRef] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var out: [MCPServerRef] = []
        var name: String?
        var command: String?
        var args: [String] = []
        var url: String?

        func flush() {
            guard let name else { return }
            out.append(server(named: name, toolID: toolID, command: command, args: args, url: url))
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                flush()
                name = nil; command = nil; args = []; url = nil
                let header = line.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                if header.hasPrefix("mcp_servers.") {
                    let rest = String(header.dropFirst("mcp_servers.".count))
                    if rest.hasPrefix("\"") || rest.hasPrefix("'") {
                        name = unquote(rest)
                    } else if rest.contains(".") {
                        name = nil        // a sub-table such as `.env`, not another server
                    } else {
                        name = rest
                    }
                }
                continue
            }
            guard name != nil, let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "command": command = unquote(value)
            case "url": url = unquote(value)
            case "args":
                args = value.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                    .split(separator: ",").map { unquote($0.trimmingCharacters(in: .whitespaces)) }
            default: break   // env and everything else is never read
            }
        }
        flush()
        return out
    }

    private static func unquote(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    // MARK: - Shared

    /// Keep only what names a process: the command's basename and the first argument that looks
    /// like a package or script. Flags and their values are dropped.
    private static func server(named name: String, toolID: String,
                               command: String?, args: [String]?, url: String?) -> MCPServerRef {
        let host = url.flatMap { URLComponents(string: $0)?.host }
        let basename = command.map { ($0 as NSString).lastPathComponent } ?? (host != nil ? "remote" : "?")
        let marker = (args ?? []).first { argument in
            !argument.hasPrefix("-") && (argument.contains("/") || argument.contains(".") || argument.contains("@"))
        }
        return MCPServerRef(toolID: toolID, name: name, command: basename, marker: marker, host: host)
    }
}
