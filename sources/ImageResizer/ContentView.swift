import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var model: ResizeViewModel
    @State private var isDropTargeted = false
    @State private var presetName = ""
    @State private var showingPresetPrompt = false

    var body: some View {
        NavigationSplitView {
            sourceSidebar
                .navigationSplitViewColumnWidth(min: 240, ideal: 270, max: 330)
        } detail: {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        dropZone
                        dimensionsSection
                        outputSection
                        metadataSection
                    }
                    .padding(24)
                }
                Divider()
                actionBar
                    .padding(18)
            }
        }
        .alert("Unable to Start", isPresented: Binding(
            get: { model.planningError != nil },
            set: { if !$0 { model.planningError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.planningError ?? "")
        }
        .alert("Save Preset", isPresented: $showingPresetPrompt) {
            TextField("Preset name", text: $presetName)
            Button("Cancel", role: .cancel) { presetName = "" }
            Button("Save") {
                let name = presetName.trimmingCharacters(in: .whitespacesAndNewlines)
                model.store.addPreset(name: name.isEmpty ? "Custom Size" : name)
                presetName = ""
            }
        }
    }

    private var sourceSidebar: some View {
        VStack(spacing: 0) {
            List {
                Section("Sources") {
                    ForEach(model.sources, id: \.self) { url in
                        Label(url.lastPathComponent, systemImage: sourceIcon(url))
                            .help(url.path)
                    }
                    .onDelete(perform: model.removeSources)
                }
            }
            HStack {
                Button(action: model.chooseSources) { Image(systemName: "plus") }
                    .help("Add files or folders")
                Button(action: model.clearSources) { Image(systemName: "trash") }
                    .disabled(model.sources.isEmpty || model.isProcessing)
                    .help("Clear sources")
                Spacer()
                Text("\(model.sources.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .padding(12)
        }
        .navigationTitle("Image Resizer")
    }

    private var dropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: model.sources.isEmpty ? "photo.on.rectangle.angled" : "checkmark.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(model.sources.isEmpty ? Color.accentColor : .green)
            Text(model.sources.isEmpty ? "Drop images and folders here" : "Ready to resize")
                .font(.title3.weight(.semibold))
            Text(model.sources.isEmpty ? "Folder structure will be preserved" : "\(model.sources.count) source item\(model.sources.count == 1 ? "" : "s") selected")
                .foregroundStyle(.secondary)
            Button("Choose Files or Folders…", action: model.chooseSources)
        }
        .frame(maxWidth: .infinity, minHeight: 150)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(isDropTargeted ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.25), style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1, dash: [7]))
        )
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted) { providers in
            loadDroppedURLs(providers)
            return true
        }
    }

    private var dimensionsSection: some View {
        GroupBox("Size") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    dimensionField("Width", text: binding(\.widthText))
                    Image(systemName: "xmark").foregroundStyle(.secondary)
                    dimensionField("Height", text: binding(\.heightText))
                    Text("px").foregroundStyle(.secondary)
                    Spacer()
                }
                Text("Images are scaled proportionally to fit. Leave one field empty to constrain only the other dimension.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Menu("Presets") {
                        ForEach(model.store.presets) { preset in
                            Button(preset.name) { model.store.apply(preset) }
                        }
                    }
                    Button("Save Preset…") { showingPresetPrompt = true }
                    Spacer()
                    if let preview = previewText { Text(preview).font(.caption).foregroundStyle(.secondary) }
                }
            }
            .padding(8)
        }
    }

    private var outputSection: some View {
        GroupBox("Output") {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Picker("Format", selection: binding(\.format)) {
                        ForEach(OutputFormat.allCases) { format in Text(format.rawValue).tag(format) }
                    }
                    .frame(maxWidth: 290)
                    Spacer()
                }

                if model.store.format == .jpeg || model.store.format == .heic || model.store.format == .webp || model.store.format == .original {
                    HStack {
                        Text("Quality")
                        Slider(value: binding(\.quality), in: 0.1...1, step: 0.01)
                        Text("\(Int(model.store.quality * 100))")
                            .monospacedDigit()
                            .frame(width: 32, alignment: .trailing)
                    }
                }

                if model.store.format == .jpeg {
                    ColorPicker("Transparency background", selection: backgroundBinding, supportsOpacity: false)
                }

                Toggle("Use a custom destination", isOn: binding(\.useCustomDestination))
                if model.store.useCustomDestination {
                    HStack {
                        Text(model.store.customDestination?.path(percentEncoded: false) ?? "No folder selected")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(model.store.customDestination == nil ? .secondary : .primary)
                        Spacer()
                        Button("Choose…", action: model.chooseDestination)
                    }
                } else {
                    Text("Each folder is written beside its source as “Folder Name - Resized”.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
        }
    }

    private var metadataSection: some View {
        GroupBox("Metadata") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Preserve metadata", isOn: binding(\.preserveMetadata))
                Toggle("Remove location data", isOn: binding(\.removeLocation))
                    .disabled(!model.store.preserveMetadata)
                Text("Orientation, dates, camera information, color profiles, and animation timing are retained when supported by the output format.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }

    private var actionBar: some View {
        VStack(spacing: 12) {
            if model.isProcessing || model.result != nil {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: model.progress.fraction)
                    HStack {
                        Text(statusText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Text("\(model.progress.processed) of \(model.progress.total)").font(.caption).monospacedDigit()
                    }
                }
            }
            HStack {
                if model.isProcessing {
                    Button(model.isPaused ? "Resume" : "Pause", action: model.togglePause)
                    Button("Cancel", role: .destructive, action: model.cancel)
                } else if model.result != nil {
                    Button("Reveal in Finder", action: model.revealOutput)
                    Text("\(model.progress.completed) completed · \(model.progress.skipped) skipped · \(model.progress.failed) failed")
                        .font(.caption)
                        .foregroundStyle(model.progress.failed == 0 ? Color.secondary : Color.red)
                }
                Spacer()
                Button("Resize", action: model.start)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!model.canResize || (model.store.useCustomDestination && model.store.customDestination == nil))
            }
        }
    }

    private var statusText: String {
        if model.isPaused { return "Paused" }
        if model.isProcessing { return model.progress.currentName.isEmpty ? "Preparing…" : "Resizing \(model.progress.currentName)" }
        if let result = model.result, !result.errors.isEmpty { return result.errors.first ?? "Finished with errors" }
        return "Finished"
    }

    private var previewText: String? {
        guard model.store.settings.isValid else { return "Enter a width or height" }
        let w = model.store.settings.width.map(String.init) ?? "∞"
        let h = model.store.settings.height.map(String.init) ?? "∞"
        return "Fits within \(w) × \(h) px"
    }

    private func dimensionField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField("Any", text: text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 110)
        }
    }

    private func binding<Value>(_ keyPath: ReferenceWritableKeyPath<SettingsStore, Value>) -> Binding<Value> {
        Binding(get: { model.store[keyPath: keyPath] }, set: { model.store[keyPath: keyPath] = $0 })
    }

    private var backgroundBinding: Binding<Color> {
        Binding(
            get: { Color(red: model.store.backgroundRed, green: model.store.backgroundGreen, blue: model.store.backgroundBlue) },
            set: { color in
                if let converted = NSColor(color).usingColorSpace(.sRGB) {
                    model.store.backgroundRed = converted.redComponent
                    model.store.backgroundGreen = converted.greenComponent
                    model.store.backgroundBlue = converted.blueComponent
                }
            }
        )
    }

    private func loadDroppedURLs(_ providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                Task { @MainActor in model.addSources([url]) }
            }
        }
    }

    private func sourceIcon(_ url: URL) -> String {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true ? "folder" : "photo"
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: ResizeViewModel

    var body: some View {
        Form {
            Section("Saved Presets") {
                List {
                    ForEach(model.store.presets) { preset in
                        HStack {
                            Text(preset.name)
                            Spacer()
                            Text("\(preset.width.map(String.init) ?? "Any") × \(preset.height.map(String.init) ?? "Any")")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onDelete(perform: model.store.deletePresets)
                }
                .frame(height: 180)
            }
        }
    }
}
