import Foundation
import PelicanKit
import PelicanRao
import PelicanUI

/// Headless diagnostics, run from the command line (see main.swift). They print what the
/// capture and identity layers see on this Mac, so a user can check Pelican's claims
/// against their own system without the UI.
enum Probes {

    /// `Pelican --capture-probe [seconds] [process-name-prefix]`
    /// Runs the monitor and prints every flow opened and closed.
    static func capture(seconds: Double, filter: String?) async {
        let monitor = NetworkMonitor()
        let stream = await monitor.snapshots()
        await monitor.start(cadence: 2)
        let deadline = Date().addingTimeInterval(seconds)
        var opened = 0, closed = 0
        var bySource: [String: Int] = [:]
        let reader = Task {
            for await snapshot in stream {
                for event in snapshot.newEvents {
                    switch event {
                    case .opened(let flow, let at):
                        guard matches(flow, filter) else { continue }
                        opened += 1
                        print("\(stamp(at)) OPEN   \(describe(flow))")
                    case .closed(let flow, let at):
                        guard matches(flow, filter) else { continue }
                        closed += 1
                        let sources = flow.seenBy.map(\.rawValue).sorted().joined(separator: "+")
                        bySource[sources, default: 0] += 1
                        print("\(stamp(at)) CLOSE  \(describe(flow))  seen by \(sources)")
                    case .verdictAssigned:
                        break
                    }
                }
                if Date() > deadline { break }
            }
        }
        try? await Task.sleep(for: .seconds(seconds))
        reader.cancel()
        await monitor.stop()
        print("---")
        print("opened \(opened), closed \(closed); closed flows by source: \(bySource)")
    }

    private static func matches(_ flow: Flow, _ filter: String?) -> Bool {
        guard let filter, !filter.isEmpty else { return true }
        return flow.processName.hasPrefix(filter)
    }

    private static func describe(_ flow: Flow) -> String {
        let remote = flow.hasConcreteRemote ? "\(flow.remoteAddress):\(flow.remotePort.map(String.init) ?? "*")" : "(listening)"
        return "\(flow.processName)[\(flow.pid)] \(flow.proto.rawValue) \(flow.direction.rawValue) \(remote) "
            + "\(flow.scope.rawValue) \(flow.state.displayLabel) in=\(flow.bytesIn) out=\(flow.bytesOut)"
    }

    private static func stamp(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute().second().secondFraction(.fractional(3)))
    }
}

extension Probes {
    /// `Pelican --identity <pid|name>`: what Pelican reads about a process.
    static func identity(_ target: String) {
        if target.hasPrefix("/") {
            guard let sig = CodeSignature.read(path: target) else { print("\(target): unreadable"); return }
            print("\(target)")
            print("  identifier \(sig.identifier ?? "-")  team \(sig.teamIdentifier ?? "-")  [\(sig.leafKind.displayName)] \(sig.leafSubject ?? "-")")
            print("  valid \(sig.isValid)  runtime \(sig.hardenedRuntime)  notarized \(sig.notarized.map(String.init) ?? "?")  adhoc \(sig.isAdHoc)")
            return
        }
        let pids: [Int32] = Int32(target).map { [$0] } ?? ProcessIdentity.pids(named: [target])
        if pids.isEmpty { print("no process \(target)") }
        for pid in pids {
            guard let identity = ProcessIdentity.read(pid: pid) else { print("pid \(pid): gone"); continue }
            print("pid \(identity.pid)  \(identity.name)  parent \(identity.parentPid.map(String.init) ?? "-")")
            print("  path        \(identity.executablePath ?? "-")")
            print("  bundle      \(identity.bundlePath ?? "-")  \(identity.bundleIdentifier ?? "")  \(identity.bundleVersion ?? "") \(identity.bundleBuild.map { "(\($0))" } ?? "")")
            print("  launched    \(identity.launchedAt?.formatted() ?? "-")")
            guard let sig = identity.signature else { print("  signature   unreadable"); continue }
            print("  identifier  \(sig.identifier ?? "-")")
            print("  team        \(sig.teamIdentifier ?? "-")")
            print("  certificate \(sig.leafSubject ?? "-")  [\(sig.leafKind.displayName)]")
            print("  valid       \(sig.isValid)\(sig.validityError.map { " — \($0)" } ?? "")")
            print("  flags       adhoc=\(sig.isAdHoc) runtime=\(sig.hardenedRuntime) linker=\(sig.linkerSigned)")
            print("  notarized   \(sig.notarized.map(String.init) ?? "unchecked")")
            print("  cdhash      \(sig.cdHash ?? "-")")
            print("  requirement \(sig.designatedRequirement ?? "-")")
            print("  development build: \(sig.isDevelopmentBuild) \(sig.developmentReasons)")
        }
    }
}

import AppKit
import SwiftUI

extension Probes {
    /// `Pelican --snapshot <file.png> [seconds]`: start watching as the app does, wait, then
    /// render the Rao screen offscreen at full height — for documentation and for checking the
    /// layout without scrolling. Uses PELICAN_LEDGER_DIR when set.
    @MainActor
    static func snapshot(to path: String, after seconds: Double) async {
        let state = AppState.shared
        state.launch()
        try? await Task.sleep(for: .seconds(seconds))
        let host = NSHostingView(rootView: RaoView(monitor: state.rao, host: state.host).frame(width: 1180)
            .background(Color.pelicanBG).preferredColorScheme(.light))
        host.frame = NSRect(x: 0, y: 0, width: 1180, height: 200)
        host.layoutSubtreeIfNeeded()
        let height = max(900, host.fittingSize.height)
        let window = NSWindow(contentRect: NSRect(x: -5000, y: 0, width: 1180, height: height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.orderFrontRegardless()
        host.frame = NSRect(x: 0, y: 0, width: 1180, height: height)
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .seconds(1.5))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { print("no bitmap"); return }
        host.cacheDisplay(in: host.bounds, to: rep)
        do {
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            print("wrote \(path) (\(Int(host.bounds.width))×\(Int(host.bounds.height)))")
        } catch {
            print("snapshot failed: \(error)")
        }
        state.rao.flushNow()
    }
}
