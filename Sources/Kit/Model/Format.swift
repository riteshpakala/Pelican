import Foundation

/// Human-readable byte count in the compact style the tables use.
package func formatBytes(_ bytes: UInt64) -> String {
    switch bytes {
    case 0..<1024: return "\(bytes) B"
    case 1024..<1_048_576: return String(format: "%.1f KB", Double(bytes) / 1024)
    case 1_048_576..<1_073_741_824: return String(format: "%.1f MB", Double(bytes) / 1_048_576)
    default: return String(format: "%.2f GB", Double(bytes) / 1_073_741_824)
    }
}
