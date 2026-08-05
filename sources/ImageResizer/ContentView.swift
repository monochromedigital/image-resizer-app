import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var model: ResizeViewModel
    @State private var isDropTargeted = false
    @State private var presetName = ""
    @State private var showingPresetPrompt = false
    @State private var selectedSources = Set<URL>()

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
                        webExportSection
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
            List(selection: $selectedSources) {
                Section("Sources") {
                    ForEach(model.sources, id: \.self) { url in
                        Label(url.lastPathComponent, systemImage: sourceIcon(url))
                            .tag(url)
                            .help(url.path)
                            .onTapGesture(count: 2) { model.revealSources([url]) }
                            .contextMenu {
                                Button("Reveal in Finder") { model.revealSources([url]) }
                                Divider()
                                Button("Remove Source", role: .destructive) { model.removeSources([url]) }
                                    .disabled(model.isProcessing)
                            }
                    }
                    .onDelete(perform: model.removeSources)
                }
            }
            .onChange(of: model.sources) { _, sources in
                selectedSources.formIntersection(sources)
            }
            HStack {
                Button(action: model.chooseSources) { Image(systemName: "plus") }
                    .disabled(model.isProcessing)
                    .help("Add files or folders")
                Button { model.removeSources(selectedSources) } label: { Image(systemName: "minus") }
                    .disabled(selectedSources.isEmpty || model.isProcessing)
                    .help("Remove selected sources")
                Button { model.revealSources(selectedSources) } label: { Image(systemName: "folder") }
                    .disabled(selectedSources.isEmpty)
                    .help("Reveal selected sources in Finder")
                Button(action: model.clearSources) { Image(systemName: "trash") }
                    .disabled(model.sources.isEmpty || model.isProcessing)
                    .help("Clear all sources")
                Spacer()
                Text(selectedSources.isEmpty ? "\(model.sources.count) sources" : "\(selectedSources.count) selected")
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
                .disabled(model.isProcessing)
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
                Picker("Resize mode", selection: binding(\.mode)) {
                    ForEach(ResizeMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                }
                .pickerStyle(.segmented)

                switch model.store.mode {
                case .fit, .fill:
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        dimensionField("Width", text: binding(\.widthText))
                        Image(systemName: "xmark").foregroundStyle(.secondary)
                        dimensionField("Height", text: binding(\.heightText))
                        Text("px").foregroundStyle(.secondary)
                        Spacer()
                    }
                case .longEdge:
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        dimensionField("Long edge", text: binding(\.longEdgeText))
                        Text("px").foregroundStyle(.secondary)
                        Spacer()
                    }
                case .percentage:
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        dimensionField("Scale", text: binding(\.percentageText))
                        Text("%").foregroundStyle(.secondary)
                        Spacer()
                    }
                }

                Text(modeHelpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Don't enlarge smaller images", isOn: binding(\.preventEnlargement))
                    .toggleStyle(.checkbox)
                if model.store.mode == .fit || model.store.mode == .fill {
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
            }
            .padding(8)
        }
        .disabled(model.isProcessing)
    }

    private var outputSection: some View {
        GroupBox("Output") {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Picker("Format", selection: binding(\.format)) {
                        ForEach(OutputFormat.writable) { format in Text(format.rawValue).tag(format) }
                    }
                    .frame(maxWidth: 290)
                    Spacer()
                }

                if model.store.format != .png && model.store.format != .tiff && model.store.format != .gif {
                    HStack {
                        Text(targetFileSizeIsActive ? "Maximum quality" : "Quality")
                        Slider(value: binding(\.quality), in: 0.1...1, step: 0.01)
                        Text("\(Int(model.store.quality * 100))")
                            .monospacedDigit()
                            .frame(width: 32, alignment: .trailing)
                    }
                }

                Toggle("Limit file size", isOn: binding(\.targetFileSizeEnabled))
                if model.store.targetFileSizeEnabled {
                    HStack {
                        TextField("500", text: binding(\.targetFileSizeText))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 110)
                        Picker("", selection: binding(\.targetFileSizeUnit)) {
                            ForEach(FileSizeUnit.allCases) { unit in Text(unit.rawValue).tag(unit) }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 110)
                        Spacer()
                    }
                    Text(targetFileSizeHelpText)
                        .font(.caption)
                        .foregroundStyle(targetFileSizeIsValid ? Color.secondary : Color.orange)
                }

                if model.store.format == .jpeg {
                    ColorPicker("Transparency background", selection: backgroundBinding, supportsOpacity: false)
                }

                HStack {
                    Text("Filename suffix")
                    TextField("-resized", text: binding(\.filenameSuffix))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                    Spacer()
                }
                Text("Added before the file extension. Leave empty to keep the original filename.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

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
        .disabled(model.isProcessing)
    }

    private var webExportSection: some View {
        GroupBox("Web Export") {
            VStack(alignment: .leading, spacing: 14) {
                Toggle("Prepare output for the web", isOn: binding(\.isWebExportEnabled))
                Text("Clean filenames, sRGB colour, and optional responsive sizes. Everything runs on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if model.store.isWebExportEnabled {
                    Divider()
                    filenameControls
                    Divider()
                    ladderControls
                    Divider()
                    formatControls
                    Divider()
                    colourControls
                    Divider()
                    rightsControls
                    Divider()
                    sidecarControls
                    Divider()
                    altTextControls
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
        .disabled(model.isProcessing)
    }

    private var filenameControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Filenames", selection: naming(\.style)) {
                Text("Keep original").tag(Naming.Style.keepOriginal)
                Text("Web-safe slug").tag(Naming.Style.slug)
            }
            .pickerStyle(.segmented)

            if model.store.webExport.naming?.style == .slug {
                HStack {
                    Text("Pattern")
                    TextField("{slug}", text: naming(\.template))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                    Spacer()
                }
                Text(namingExampleText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Transliterate accents and other scripts", isOn: naming(\.transliterate))
                Toggle("Strip camera prefixes like IMG_ and DSC_", isOn: naming(\.stripCameraPrefixes))
            }
        }
    }

    private var ladderControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Generate multiple sizes", isOn: binding(\.isLadderEnabled))
                .disabled(!SizeLadder.applies(to: model.store.mode))
            if !SizeLadder.applies(to: model.store.mode) {
                Text("Percentage scales relative to each source, so there are no fixed widths to generate.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if model.store.isLadderEnabled {
                HStack {
                    Text("Widths")
                    TextField("400, 800, 1200, 1600", text: binding(\.ladderWidthsText))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 240)
                    Text("px").foregroundStyle(.secondary)
                    Spacer()
                }
                Toggle("Skip sizes larger than the original", isOn: ladder(\.skipUpscales))
                Toggle("Also keep the original size", isOn: ladder(\.includeOriginalSize))
            }
        }
    }

    private var formatControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Formats")
                .font(.subheadline.weight(.medium))
            Toggle("Also write AVIF", isOn: formatAlternative(.avif))
                .disabled(!OutputFormat.writable.contains(.avif))
            if !OutputFormat.writable.contains(.avif) {
                Text("This version of macOS cannot write AVIF.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle("Also write WebP", isOn: formatAlternative(.webp))
            Text("Each image is written in these formats as well as \(model.store.format.rawValue), and the markup offers them in order so a browser takes the best one it understands.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(outputCountText)
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()
            Toggle("Also write a link preview image", isOn: binding(\.isSocialImageEnabled))
            if model.store.isSocialImageEnabled {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Preview size").frame(width: 108, alignment: .leading)
                    TextField("1200", text: socialDimension(\.width))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 80)
                    Image(systemName: "xmark").foregroundStyle(.secondary)
                    TextField("630", text: socialDimension(\.height))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 80)
                    Text("px").foregroundStyle(.secondary)
                    Spacer()
                }
            }
            Text("One extra JPEG per image, cropped to fill, for the card that appears when a link is shared. The markup carries og:image tags for the first image. It never joins the responsive sizes — it is a different crop, not a smaller one.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Kept as text so a half-typed number does not momentarily become a valid size.
    private func socialDimension(_ keyPath: WritableKeyPath<SocialImage, Int>) -> Binding<String> {
        Binding(
            get: {
                let value = (model.store.webExport.social ?? SocialImage())[keyPath: keyPath]
                return value > 0 ? String(value) : ""
            },
            set: {
                var updated = model.store.webExport.social ?? SocialImage()
                updated[keyPath: keyPath] = Int($0.filter(\.isNumber)) ?? 0
                model.store.webExport.social = updated
            }
        )
    }

    /// Membership of the alternative-format list, kept in the order the markup needs
    /// rather than the order the boxes were ticked.
    private func formatAlternative(_ format: OutputFormat) -> Binding<Bool> {
        Binding(
            get: {
                model.store.webExport.formats?.alternatives.contains { $0.format == format } ?? false
            },
            set: { isOn in
                var alternatives = model.store.webExport.formats?.alternatives ?? []
                alternatives.removeAll { $0.format == format }
                if isOn { alternatives.append(FormatPlan.Entry(format: format)) }
                model.store.webExport.formats = alternatives.isEmpty
                    ? nil
                    : FormatPlan(alternatives: FormatPlan.sorted(alternatives))
            }
        )
    }

    private var rightsControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rights")
                .font(.subheadline.weight(.medium))
            rightsField("Creator", placeholder: "Your name or studio", value: rights(\.creator))
            if model.store.webExport.rights?.creator?.isEmpty == false {
                Picker("Creator is", selection: rightsValue(\.creatorType)) {
                    Text("A person").tag(RightsMetadata.CreatorType.person)
                    Text("An organisation").tag(RightsMetadata.CreatorType.organization)
                }
                .frame(maxWidth: 320)
            }
            rightsField("Copyright", placeholder: "© 2026 Your Name", value: rights(\.copyrightNotice))
            rightsField("Credit", placeholder: "Photo: Your Name", value: rights(\.credit))
            rightsField("Licence page", placeholder: "https://example.com/licence", value: rights(\.webStatementURL))
            rightsField("Licensing page", placeholder: "https://example.com/buy", value: rights(\.licensorURL))
            Text("Written into every exported file. URLs are stored as text — nothing is ever fetched.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Title", selection: rightsValue(\.titlePolicy)) {
                Text("Keep existing").tag(RightsMetadata.TextPolicy.keepExisting)
                Text("From filename").tag(RightsMetadata.TextPolicy.fromFilename)
                Text("Leave empty").tag(RightsMetadata.TextPolicy.empty)
            }
            .frame(maxWidth: 320)
            // A suggestion describes the picture, which is what a description is for.
            // It is deliberately not offered for Title: a title names an image rather
            // than describing it.
            Picker("Description", selection: rightsValue(\.descriptionPolicy)) {
                Text("Keep existing").tag(RightsMetadata.TextPolicy.keepExisting)
                Text("From filename").tag(RightsMetadata.TextPolicy.fromFilename)
                Text("From suggested alt text").tag(RightsMetadata.TextPolicy.fromAltText)
                Text("Leave empty").tag(RightsMetadata.TextPolicy.empty)
            }
            .frame(maxWidth: 320)
            if model.store.webExport.rights?.descriptionPolicy == .fromAltText, !model.store.isAltTextEnabled {
                Text("Turn on “Suggest alt text” below, or descriptions will be left as they are.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Titles and descriptions differ per image, so only the rule is remembered — never the text.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var altTextControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Suggest alt text", isOn: binding(\.isAltTextEnabled))
            if model.store.isAltTextEnabled {
                Picker("Wording", selection: altTextEngine()) {
                    Text("Detected labels").tag(AltText.Engine.labelsOnly)
                    Text("Phrased").tag(AltText.Engine.automatic)
                }
                .frame(maxWidth: 320)
                Text("Recognition runs on this Mac, and phrasing uses the on-device language model where one is available. Suggestions only ever repeat what was detected, and images the recogniser is unsure about are left undescribed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Review suggestions before publishing — they describe what was recognised, which is not always what matters about a picture.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func altTextEngine() -> Binding<AltText.Engine> {
        Binding(
            get: { (model.store.webExport.altText ?? AltText()).engine },
            set: {
                var updated = model.store.webExport.altText ?? AltText()
                updated.engine = $0
                model.store.webExport.altText = updated
            }
        )
    }

    private var sidecarControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Write a manifest and ready-to-paste markup", isOn: binding(\.areSidecarsEnabled))
            if model.store.areSidecarsEnabled {
                rightsField("Path prefix", placeholder: "/images", value: sidecar(\.pathPrefix))
                Picker("Image width", selection: sidecar(\.layout)) {
                    Text("Full page width").tag(Sidecars.Layout.fullWidth)
                    Text("Half the page").tag(Sidecars.Layout.half)
                    Text("A third of the page").tag(Sidecars.Layout.thirds)
                    Text("A quarter of the page").tag(Sidecars.Layout.quarter)
                    Text("A fixed column").tag(Sidecars.Layout.fixedWidth)
                    Text("Custom…").tag(Sidecars.Layout.custom)
                }
                .frame(maxWidth: 320)
                switch sidecarLayout {
                case .fixedWidth:
                    HStack {
                        Text("Column width").frame(width: 108, alignment: .leading)
                        TextField("800", text: layoutMaxWidthText)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 90)
                        Text("px").foregroundStyle(.secondary)
                        Spacer()
                    }
                case .custom:
                    rightsField("sizes", placeholder: "100vw", value: sidecar(\.sizesAttribute))
                default:
                    EmptyView()
                }
                Text("How wide the image sits on your page. The browser picks a size before the page has a layout, so it can only go by this — “Full page width” on a narrow column makes it fetch the largest file every time. Emitted as sizes=\"\(model.store.webExport.sidecars?.resolvedSizes ?? "100vw")\".")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Placeholder", selection: sidecar(\.placeholder)) {
                    Text("None").tag(Sidecars.PlaceholderMode.none)
                    Text("Inline blur-up").tag(Sidecars.PlaceholderMode.base64DataURI)
                }
                .frame(maxWidth: 320)
                Toggle("Describe the images for search engines", isOn: sidecar(\.structuredData))
                Text("Adds a schema.org block to the markup carrying the credit and licence details above. Search engines read it from the page, which survives uploads that strip a file's own metadata.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Load the first image first", isOn: sidecar(\.prioritiseFirstImage))
                Text("The largest image on screen should not wait its turn. The first image of the batch is marked to load immediately; the rest load lazily. Drop your hero image first, or turn this off if none of them is one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("manifest.json and snippet.html are written beside the images. Paths use the prefix, so they describe where the files will live rather than where they were written.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var sidecarLayout: Sidecars.Layout {
        (model.store.webExport.sidecars ?? Sidecars()).layout
    }

    /// Empty rather than `0` while the field is being cleared, so the placeholder shows
    /// through instead of a zero the user has to select and type over.
    private var layoutMaxWidthText: Binding<String> {
        Binding(
            get: {
                let width = (model.store.webExport.sidecars ?? Sidecars()).layoutMaxWidth
                return width > 0 ? String(width) : ""
            },
            set: {
                var updated = model.store.webExport.sidecars ?? Sidecars()
                updated.layoutMaxWidth = Int($0.filter(\.isNumber)) ?? 0
                model.store.webExport.sidecars = updated
            }
        )
    }

    private func sidecar<Value>(_ keyPath: WritableKeyPath<Sidecars, Value>) -> Binding<Value> {
        Binding(
            get: { (model.store.webExport.sidecars ?? Sidecars())[keyPath: keyPath] },
            set: {
                var updated = model.store.webExport.sidecars ?? Sidecars()
                updated[keyPath: keyPath] = $0
                model.store.webExport.sidecars = updated
            }
        )
    }

    private func rightsField(_ title: String, placeholder: String, value: Binding<String>) -> some View {
        HStack {
            Text(title).frame(width: 108, alignment: .leading)
            TextField(placeholder, text: value)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)
            Spacer()
        }
    }

    /// Optional strings bind as empty text, so a cleared field stores nothing rather than
    /// an empty string that `hasContent` would have to special-case.
    private func rights(_ keyPath: WritableKeyPath<RightsMetadata, String?>) -> Binding<String> {
        Binding(
            get: { (model.store.webExport.rights ?? RightsMetadata())[keyPath: keyPath] ?? "" },
            set: {
                var updated = model.store.webExport.rights ?? RightsMetadata()
                updated[keyPath: keyPath] = $0.isEmpty ? nil : $0
                model.store.webExport.rights = updated
            }
        )
    }

    private func rightsValue<Value>(
        _ keyPath: WritableKeyPath<RightsMetadata, Value>
    ) -> Binding<Value> {
        Binding(
            get: { (model.store.webExport.rights ?? RightsMetadata())[keyPath: keyPath] },
            set: {
                var updated = model.store.webExport.rights ?? RightsMetadata()
                updated[keyPath: keyPath] = $0
                model.store.webExport.rights = updated
            }
        )
    }

    private var colourControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Colour profile", selection: colour(\.embedProfile)) {
                Text("Untagged").tag(ColorPolicy.ProfileMode.untagged)
                Text("Embed sRGB").tag(ColorPolicy.ProfileMode.sRGB)
            }
            .frame(maxWidth: 290)
            Text("Output is always converted to sRGB. Browsers read untagged images as sRGB; embed a profile if your pipeline expects one.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Shows the naming pattern applied to a representative filename, so the effect of a
    /// template is visible without running a batch.
    private var namingExampleText: String {
        guard let naming = model.store.webExport.naming else { return "" }
        let example = OutputNaming.stem(
            source: URL(fileURLWithPath: "/Photos/IMG_4821 Café Sign.jpg"),
            naming: naming,
            filenameSuffix: model.store.filenameSuffix,
            outputExtension: "jpg",
            outputSize: CGSize(width: 800, height: 600)
        )
        return "IMG_4821 Café Sign.jpg → \(example).jpg"
    }

    /// The per-image multiplier, computed from settings alone. A true total needs a full
    /// plan — every dropped folder walked — which is far too expensive for a label that
    /// updates as you type. The exact figure appears in the progress bar once planning
    /// has run.
    private var outputCountText: String {
        let settings = model.store.settings
        let rungs = SizeLadder.expand(settings, sourceSize: nil).count
        let formats = FormatMatrix.count(for: settings)
        let share = settings.webExport?.social?.isValid == true ? 1 : 0
        let files = rungs * formats + share
        guard files > 1 else { return "One file per image." }
        var breakdown = rungs > 1 && formats > 1 ? "\(rungs) sizes × \(formats) formats" : ""
        if share > 0 { breakdown += breakdown.isEmpty ? "including the link preview" : ", plus the link preview" }
        let detail = breakdown.isEmpty ? "" : " (\(breakdown))"
        return "Up to \(files) files per image\(detail). Sizes larger than a given original are skipped."
    }

    private func naming<Value>(_ keyPath: WritableKeyPath<Naming, Value>) -> Binding<Value> {
        Binding(
            get: { (model.store.webExport.naming ?? Naming())[keyPath: keyPath] },
            set: {
                var updated = model.store.webExport.naming ?? Naming()
                updated[keyPath: keyPath] = $0
                model.store.webExport.naming = updated
            }
        )
    }

    private func ladder<Value>(_ keyPath: WritableKeyPath<Ladder, Value>) -> Binding<Value> {
        Binding(
            get: { (model.store.webExport.ladder ?? Ladder())[keyPath: keyPath] },
            set: {
                var updated = model.store.webExport.ladder ?? Ladder()
                updated[keyPath: keyPath] = $0
                model.store.webExport.ladder = updated
            }
        )
    }

    private func colour<Value>(_ keyPath: WritableKeyPath<ColorPolicy, Value>) -> Binding<Value> {
        Binding(
            get: { (model.store.webExport.color ?? ColorPolicy())[keyPath: keyPath] },
            set: {
                var updated = model.store.webExport.color ?? ColorPolicy()
                updated[keyPath: keyPath] = $0
                model.store.webExport.color = updated
            }
        )
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
        .disabled(model.isProcessing)
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
        guard model.store.settings.isValid else { return invalidSizeText }
        if let widths = model.store.settings.webExport?.ladder?.normalisedWidths,
           !widths.isEmpty, SizeLadder.applies(to: model.store.mode) {
            return "Web Export sizes: \(Ladder.formatWidths(widths)) px"
        }
        switch model.store.mode {
        case .fit:
            let w = model.store.settings.width.map(String.init) ?? "∞"
            let h = model.store.settings.height.map(String.init) ?? "∞"
            return "Fits within \(w) × \(h) px"
        case .fill:
            return "Fills and crops to \(model.store.widthText) × \(model.store.heightText) px"
        case .longEdge:
            return "Long edge: \(model.store.longEdgeText) px"
        case .percentage:
            return "Scale: \(model.store.percentageText)%"
        }
    }

    private var invalidSizeText: String {
        switch model.store.mode {
        case .fit: "Enter a width or height"
        case .fill: "Enter both width and height"
        case .longEdge: "Enter a long-edge size"
        case .percentage: "Enter a percentage"
        }
    }

    private var modeHelpText: String {
        switch model.store.mode {
        case .fit: "Scale proportionally inside the width and height. Either dimension may be empty."
        case .fill: "Fill the exact width and height, cropping equally from opposite edges."
        case .longEdge: "Set the longest side and preserve the image's proportions."
        case .percentage: "Scale both dimensions by a percentage of the original size."
        }
    }

    private var targetFileSizeHelpText: String {
        if !model.store.format.supportsTargetFileSize {
            return "Choose a lossy format — JPEG, HEIC, AVIF, or WebP — to use a target file size."
        }
        if model.store.settings.targetFileSizeBytes == nil {
            return "Enter a file size greater than zero."
        }
        return "Uses the highest quality up to the selected maximum while staying under this limit."
    }

    private var targetFileSizeIsValid: Bool {
        model.store.format.supportsTargetFileSize && model.store.settings.targetFileSizeBytes != nil
    }

    private var targetFileSizeIsActive: Bool {
        model.store.targetFileSizeEnabled && model.store.format.supportsTargetFileSize
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
