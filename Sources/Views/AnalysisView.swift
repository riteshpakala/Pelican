import SwiftUI

struct AnalysisView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedPreset: AnalysisPreset? = AnalysisPreset.all.first
    @State private var customPrompt = ""
    @State private var scope: AppState.AnalysisScope = .active
    @State private var showRaw = false

    var body: some View {
        // The engine is a nested ObservableObject on AppState; observe it in a
        // child view so its @Published changes re-render.
        AnalysisContent(
            engine: appState.analysis,
            selectedPreset: $selectedPreset,
            customPrompt: $customPrompt,
            scope: $scope,
            showRaw: $showRaw
        )
    }
}

private struct AnalysisContent: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var engine: AnalysisEngine
    @Binding var selectedPreset: AnalysisPreset?
    @Binding var customPrompt: String
    @Binding var scope: AppState.AnalysisScope
    @Binding var showRaw: Bool

    private var instruction: String {
        let custom = customPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if let preset = selectedPreset {
            return custom.isEmpty ? preset.prompt : preset.prompt + "\n\nAdditionally: " + custom
        }
        return custom
    }

    private var presetName: String {
        selectedPreset?.name ?? "Custom"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                presetGrid
                customPromptCard
                runBar
                if let error = engine.analysisError {
                    Text(error)
                        .font(.pelicanSans(12))
                        .foregroundStyle(Color.pelicanError)
                }
                if !engine.results.isEmpty || engine.isAnalyzing {
                    resultsCard
                }
                if !engine.rawOutput.isEmpty {
                    rawOutputCard
                }
            }
            .padding(24)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Analysis")
                .font(.pelicanSerif(26, weight: .light, italic: true))
                .foregroundStyle(Color.pelicanInk)
            Text("hunt for suspicious patterns with the on-device model")
                .font(.pelicanSans(12))
                .foregroundStyle(Color.pelicanInk.opacity(0.45))
        }
    }

    private var presetGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Presets")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 10)], spacing: 10) {
                ForEach(AnalysisPreset.all) { preset in
                    presetCard(preset)
                }
            }
        }
    }

    private func presetCard(_ preset: AnalysisPreset) -> some View {
        let selected = selectedPreset == preset
        return Button {
            selectedPreset = selected ? nil : preset
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: preset.symbol)
                        .foregroundStyle(selected ? Color.pelicanGold : Color.pelicanInk.opacity(0.5))
                    Text(preset.name)
                        .font(.pelicanSans(12, weight: .semibold))
                        .foregroundStyle(Color.pelicanInk)
                    Spacer()
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.pelicanGold)
                            .font(.system(size: 12))
                    }
                }
                Text(preset.summary)
                    .font(.pelicanSans(10.5))
                    .foregroundStyle(Color.pelicanInk.opacity(0.5))
                    .multilineTextAlignment(.leading)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 11)
                    .fill(selected ? Color.pelicanGold.opacity(0.10) : Color.pelicanCard)
                    .overlay(
                        RoundedRectangle(cornerRadius: 11)
                            .strokeBorder(selected ? Color.pelicanGold.opacity(0.5) : Color.pelicanBorder, lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
    }

    private var customPromptCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(selectedPreset == nil ? "Custom prompt" : "Custom prompt (appended to preset)")
            TextEditor(text: $customPrompt)
                .font(.pelicanSans(12))
                .foregroundStyle(Color.pelicanLabel)
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(height: 70)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(Color.white.opacity(0.6))
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.pelicanBorder, lineWidth: 1))
                )
                .overlay(alignment: .topLeading) {
                    if customPrompt.isEmpty {
                        Text("e.g. flag anything talking to a country-code TLD host, or any process my company doesn't ship…")
                            .font(.pelicanSerif(12, italic: true))
                            .foregroundStyle(Color.pelicanInk.opacity(0.3))
                            .padding(.top, 12)
                            .padding(.leading, 14)
                            .allowsHitTesting(false)
                    }
                }
        }
    }

    private var runBar: some View {
        HStack(spacing: 12) {
            if engine.isAnalyzing {
                Button("Cancel") { engine.cancel() }
                    .buttonStyle(.pelicanQuiet)
                ProgressView()
                    .controlSize(.small)
                Text(engine.progressText)
                    .font(.pelicanSans(11))
                    .foregroundStyle(Color.pelicanInk.opacity(0.5))
            } else {
                Button("Run analysis") {
                    appState.runAnalysis(instruction: instruction, presetName: presetName, scope: scope)
                }
                .buttonStyle(.pelican)
                .disabled(!appState.modelReady || instruction.isEmpty)

                if !appState.modelReady {
                    Text("Load the model first — Model tab")
                        .font(.pelicanSans(11))
                        .foregroundStyle(Color.pelicanInk.opacity(0.45))
                }
            }

            Spacer()

            Picker("", selection: $scope) {
                ForEach(AppState.AnalysisScope.allCases) { scope in
                    Text(scope.rawValue).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
        }
    }

    private var resultsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Findings")
            if engine.results.isEmpty {
                Text(engine.isAnalyzing ? "Waiting for the first verdicts…" : "No findings.")
                    .font(.pelicanSans(12))
                    .foregroundStyle(Color.pelicanInk.opacity(0.45))
            }
            ForEach(engine.results) { result in
                PelicanCard(padding: 12) {
                    HStack(spacing: 10) {
                        VerdictBadge(verdict: result.verdict)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(result.flow.processName)
                                    .font(.pelicanSans(12, weight: .semibold))
                                    .foregroundStyle(Color.pelicanInk)
                                Text("→ \(result.flow.resolvedHost ?? result.flow.remoteAddress)\(result.flow.remotePort.map { ":\($0)" } ?? "")")
                                    .font(.pelicanMono(11))
                                    .foregroundStyle(Color.pelicanInk.opacity(0.6))
                            }
                            Text(result.verdict.reason)
                                .font(.pelicanSans(11))
                                .foregroundStyle(Color.pelicanInk.opacity(0.55))
                        }
                        Spacer()
                        Text(result.verdict.presetName)
                            .font(.pelicanMono(9))
                            .foregroundStyle(Color.pelicanInk.opacity(0.35))
                    }
                }
            }
        }
    }

    private var rawOutputCard: some View {
        DisclosureGroup(isExpanded: $showRaw) {
            ScrollView {
                Text(engine.rawOutput)
                    .font(.pelicanMono(10))
                    .foregroundStyle(Color.pelicanInk.opacity(0.7))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 200)
            .padding(.top, 6)
        } label: {
            SectionLabel("Raw model output")
        }
    }
}
