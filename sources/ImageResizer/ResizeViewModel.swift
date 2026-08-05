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
                // A pre-pass rather than per-job work: alt text describes a source, and a
                // ladder turns one source into several jobs that would otherwise each ask
                // the same question. Suggestions ride along on the job so both the written
                // metadata and the generated markup can use them.
                var jobs = jobs
                if let altSettings = settings.webExport?.altText, altSettings.isEnabled {
                    let uniqueSources = NSOrderedSet(array: jobs.map(\.source)).array as? [URL] ?? []
                    let suggestions = await AltTextGenerator.generate(for: uniqueSources, settings: altSettings)
                    if !suggestions.isEmpty {
                        jobs = jobs.map {
                            ResizeJob(
                                source: $0.source,
                                output: $0.output,
                                settings: $0.settings,
                                altText: suggestions[$0.source],
                                role: $0.role
                            )
                        }
                    }
                }
                var batch = await ResizeEngine.process(jobs: jobs, skipped: skipped, control: control) { update in
                    Task { @MainActor in self.progress = update }
                }
                batch = BatchResult(
                    progress: batch.progress,
                    outputDirectories: outputDirectories,
                    errors: batch.errors,
                    renditions: batch.renditions
                )
                // Off the main actor: writing a placeholder decodes a thumbnail per
                // source, which is cheap individually and not free across a large batch.
                let written = batch.renditions
                let directories = outputDirectories
                let batchSettings = settings
                await Task.detached(priority: .utility) {
                    try? SidecarWriter.write(
                        renditions: written,
                        outputDirectories: directories,
                        settings: batchSettings
                    )
                }.value
                self.progress = batch.progress
                self.result = batch
                self.sources.removeAll()
                self.isProcessing = false
                self.isPaused = false
                self.task = nil
                self.control = nil
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
