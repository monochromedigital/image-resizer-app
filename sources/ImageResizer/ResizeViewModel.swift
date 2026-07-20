import Foundation
import AppKit
import Combine

@MainActor
final class ResizeViewModel: ObservableObject {
    @Published var sources: [URL] = []
    @Published var progress = BatchProgress()
    @Published var isProcessing = false
    @Published var isPaused = false
    @Published var result: BatchResult?
    @Published var planningError: String?

    let store = SettingsStore()
    private var task: Task<Void, Never>?
    private var control: ProcessingControl?
    private var settingsObservation: AnyCancellable?

    init() {
        settingsObservation = store.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    var canResize: Bool { !sources.isEmpty && store.settings.isValid && !isProcessing }

    func addSources(_ urls: [URL]) {
        guard !isProcessing else { return }
        let normalized = urls.map(\.standardizedFileURL)
        for url in normalized where !sources.contains(url) { sources.append(url) }
        result = nil
    }

    func chooseSources() {
        guard !isProcessing else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        if panel.runModal() == .OK { addSources(panel.urls) }
    }

    func chooseDestination() {
        guard !isProcessing else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK {
            store.customDestination = panel.url
            store.useCustomDestination = true
        }
    }

    func removeSources(at offsets: IndexSet) {
        guard !isProcessing else { return }
        sources.remove(atOffsets: offsets)
        result = nil
    }

    func removeSources(_ selectedSources: Set<URL>) {
        guard !isProcessing else { return }
        sources.removeAll { selectedSources.contains($0) }
        result = nil
    }

    func clearSources() {
        guard !isProcessing else { return }
        sources.removeAll()
        result = nil
    }

    func revealSources(_ selectedSources: Set<URL>) {
        guard !selectedSources.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(Array(selectedSources))
    }

    func start() {
        guard canResize else { return }
        let settings = store.settings
        let access = sources.filter { $0.startAccessingSecurityScopedResource() }
        do {
            let (jobs, outputDirectories, skipped) = try JobPlanner.plan(sources: sources, settings: settings)
            guard !jobs.isEmpty else {
                planningError = "No readable images were found."
                access.forEach { $0.stopAccessingSecurityScopedResource() }
                return
            }
            planningError = nil
            progress = BatchProgress(skipped: skipped, total: jobs.count + skipped)
            result = nil
            isProcessing = true
            isPaused = false
            let control = ProcessingControl()
            self.control = control

            task = Task {
                var batch = await ResizeEngine.process(jobs: jobs, skipped: skipped, settings: settings, control: control) { update in
                    Task { @MainActor in self.progress = update }
                }
                batch = BatchResult(progress: batch.progress, outputDirectories: outputDirectories, errors: batch.errors)
                self.progress = batch.progress
                self.result = batch
                self.isProcessing = false
                self.isPaused = false
                access.forEach { $0.stopAccessingSecurityScopedResource() }
            }
        } catch {
            planningError = error.localizedDescription
            access.forEach { $0.stopAccessingSecurityScopedResource() }
        }
    }

    func togglePause() {
        isPaused.toggle()
        control?.setPaused(isPaused)
    }

    func cancel() {
        control?.cancel()
        task?.cancel()
        isPaused = false
    }

    func revealOutput() {
        guard let directory = result?.outputDirectories.first else { return }
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }
}
