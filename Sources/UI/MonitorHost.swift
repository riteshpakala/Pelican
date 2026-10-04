import PelicanKit

/// What a feature screen may read from, and ask of, the app hosting it. A value: the app
/// rebuilds it whenever its own state changes, so a screen holding one stays current.
package struct MonitorHost {
    package var monitorRunning: Bool
    package var pollInterval: Double
    package var modelReady: Bool
    /// Resume (true) or pause (false) all watching.
    package var setMonitoring: @MainActor (Bool) -> Void
    /// Hand flows to the on-device analyst and show the Analysis screen.
    package var analyze: @MainActor (_ instruction: String, _ presetName: String, _ flows: [Flow]) -> Void

    package init(
        monitorRunning: Bool, pollInterval: Double, modelReady: Bool,
        setMonitoring: @escaping @MainActor (Bool) -> Void,
        analyze: @escaping @MainActor (_ instruction: String, _ presetName: String, _ flows: [Flow]) -> Void
    ) {
        self.monitorRunning = monitorRunning
        self.pollInterval = pollInterval
        self.modelReady = modelReady
        self.setMonitoring = setMonitoring
        self.analyze = analyze
    }
}
