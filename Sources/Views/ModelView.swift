import SwiftUI

struct ModelView: View {
    @EnvironmentObject private var appState: AppState
    @State private var newModelId = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if !appState.metallibPresent {
                    metallibBanner
                }
                modelListCard
                statusCard
            }
            .padding(24)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Model")
                .font(.pelicanSerif(26, weight: .light, italic: true))
                .foregroundStyle(Color.pelicanInk)
            Text("the on-device analyst — a Mistral MLX model, fully local")
                .font(.pelicanSans(12))
                .foregroundStyle(Color.pelicanInk.opacity(0.45))
        }
    }

    private var metallibBanner: some View {
        PelicanCard(padding: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(Color.pelicanError)
                    Text("mlx.metallib missing next to the binary — inference will fail at the first token")
                        .font(.pelicanSans(12, weight: .semibold))
                        .foregroundStyle(Color.pelicanInk)
                }
                Text("Run this once after each build, then relaunch:")
                    .font(.pelicanSans(11))
                    .foregroundStyle(Color.pelicanInk.opacity(0.55))
                Text("cd /Users/ritesh/Desktop/Pelican && ./build-metallib.sh debug")
                    .font(.pelicanMono(11))
                    .foregroundStyle(Color.pelicanInk)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.pelicanFill))
                    .textSelection(.enabled)
            }
        }
    }

    private var modelListCard: some View {
        PelicanCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel("Models")
                ForEach(appState.knownModels, id: \.self) { id in
                    Button {
                        appState.modelId = id
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: appState.modelId == id ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(appState.modelId == id ? Color.pelicanGold : Color.pelicanInk.opacity(0.3))
                            Text(id)
                                .font(.pelicanMono(12))
                                .foregroundStyle(Color.pelicanInk)
                            if id == ModelStore.defaultModelId {
                                Text("default")
                                    .font(.pelicanSans(9, weight: .medium))
                                    .foregroundStyle(Color.pelicanInk.opacity(0.4))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Color.pelicanFill))
                            }
                            Spacer()
                            if appState.modelReady && appState.modelId == id {
                                StatusDot(color: .pelicanGreen)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }

                HStack(spacing: 8) {
                    TextField("add a HuggingFace MLX model id…", text: $newModelId)
                        .textFieldStyle(.plain)
                        .font(.pelicanMono(12))
                        .foregroundStyle(Color.pelicanLabel)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(Color.white.opacity(0.6))
                                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.pelicanBorder, lineWidth: 1))
                        )
                        .onSubmit(addModel)
                    Button("Add") { addModel() }
                        .buttonStyle(.pelicanQuiet)
                }

                HStack(spacing: 12) {
                    Button(appState.modelReady ? "Reload model" : "Download & load") {
                        appState.warmModel()
                    }
                    .buttonStyle(.pelican)
                    .disabled(appState.warmProgress != nil)

                    if let progress = appState.warmProgress {
                        ProgressView(value: progress)
                            .frame(width: 220)
                    }
                    if !appState.warmStatus.isEmpty {
                        Text(appState.warmStatus)
                            .font(.pelicanSans(11))
                            .foregroundStyle(appState.modelReady ? Color.pelicanGreen : Color.pelicanInk.opacity(0.5))
                    }
                }

                if let error = appState.modelError {
                    Text(error)
                        .font(.pelicanMono(10))
                        .foregroundStyle(Color.pelicanError)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var statusCard: some View {
        PelicanCard(padding: 14) {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("Notes")
                Text("Models are downloaded once from HuggingFace and cached in ~/Library/Caches/models. The default 4-bit Mistral-7B-Instruct is ~4.1 GB and needs ~5 GB of memory while loaded. All analysis runs on this Mac — no flow data ever leaves the machine.")
                    .font(.pelicanSans(11.5))
                    .foregroundStyle(Color.pelicanInk.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func addModel() {
        let id = newModelId.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return }
        if !appState.knownModels.contains(id) {
            appState.knownModels.append(id)
        }
        appState.modelId = id
        newModelId = ""
    }
}
