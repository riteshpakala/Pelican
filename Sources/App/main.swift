import AppKit
import PelicanAITools
import PelicanAnalyst
import PelicanKit
import PelicanRao

let arguments = CommandLine.arguments

func argument(after flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    let value = arguments[index + 1]
    return value.hasPrefix("--") ? nil : value
}

if arguments.contains("--capture-probe") {
    // Print every flow the capture layer opens and closes, optionally for one process name.
    let seconds = argument(after: "--capture-probe").flatMap(Double.init) ?? 15
    let filter = arguments.last.flatMap { $0.hasPrefix("--") || Double($0) != nil || $0 == arguments[0] ? nil : $0 }
    Task {
        await Probes.capture(seconds: seconds, filter: filter)
        exit(0)
    }
    RunLoop.main.run()
} else if arguments.contains("--trust-probe") {
    let seconds = argument(after: "--trust-probe").flatMap(Double.init) ?? 12
    Task { @MainActor in
        await RaoProbe.trust(seconds: seconds)
        exit(0)
    }
    RunLoop.main.run()
} else if arguments.contains("--tunnel") {
    // `--tunnel status|install|remove`: drive the network extension headlessly, so the
    // packaging can be checked without the UI.
    let action = argument(after: "--tunnel") ?? "status"
    NSApplication.shared.setActivationPolicy(.accessory)
    Task { @MainActor in
        await TunnelProbe.run(action)
        exit(0)
    }
    NSApplication.shared.run()
} else if arguments.contains("--ai-probe") {
    // What Pelican can see of the AI tools on this Mac, and how each connection is sourced.
    let seconds = argument(after: "--ai-probe").flatMap(Double.init) ?? 20
    Task {
        await AIToolsProbe.run(seconds: seconds)
        exit(0)
    }
    RunLoop.main.run()
} else if let path = argument(after: "--snapshot") {
    // `--snapshot <file.png> [seconds] [rao|ai-tools]`
    let rest = arguments.drop { $0 != path }.dropFirst()
    let seconds = rest.compactMap(Double.init).first ?? 10
    let screen: Screen = rest.contains("ai-tools") ? .aiTools
        : (rest.contains("window") ? .connections : .rao)
    NSApplication.shared.setActivationPolicy(.accessory)
    Task { @MainActor in
        await Probes.snapshot(to: path, after: seconds, screen: screen)
        exit(0)
    }
    NSApplication.shared.run()
} else if let target = argument(after: "--identity") {
    Probes.identity(target)
    exit(0)
} else if arguments.contains("--selftest") {
    // Headless smoke test of the inference path: warm the default model, run
    // one tiny analysis batch, print parsed verdicts, exit non-zero on failure.
    Task {
        print(BuildInfo.current.line)
        do {
            let session = LLMSession(modelId: ModelStore.defaultModelId)
            try await session.warmup()
            print("model loaded ✓")
            let table = """
            row\tprocess\tpid\tdir\tproto\tremote\thost\tport\tin_B\tout_B\tage_s\tstate
            1\tunknown-helper\t999\tout\ttcp4\t45.133.1.7\t-\t8443\t512\t9485760\t42\tEstablished
            2\tapsd\t368\tout\ttcp4\t17.57.144.23\tcourier.push.apple.com\t5223\t88867\t282427\t3600\tEstablished
            """
            var reply = ""
            for try await chunk in await session.reply(
                system: AnalysisEngine.systemPrompt,
                user: "Flag anything suspicious.\n\nFlows:\n" + table + AnalysisEngine.replyReminder,
                maxTokens: 256
            ) {
                reply += chunk
            }
            print(reply)
            print("---")
            let verdicts = AnalysisEngine.parseVerdicts(from: reply, presetName: "selftest")
            for (row, verdict) in verdicts {
                print("row \(row): \(verdict.label.rawValue) score=\(verdict.score) — \(verdict.reason)")
            }
            print(verdicts.isEmpty ? "selftest: no verdicts parsed ✗" : "selftest passed ✓")
            exit(verdicts.isEmpty ? 1 : 0)
        } catch {
            print("selftest failed: \(error)")
            exit(1)
        }
    }
    RunLoop.main.run()
} else {
    // SPM executables launch as background processes by default. Setting
    // .regular before App.main() makes macOS treat this as a normal foreground
    // app with a dock icon and windows.
    NSApplication.shared.setActivationPolicy(.regular)
    PelicanApp.main()
}
