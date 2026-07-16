import AppKit
import SwiftUI

struct MaterialLayersPanel: View {
    @ObservedObject var model: TerrainModel
    let viewport: TerrainMTKView

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Image(systemName: "square.stack.3d.up.fill")
                    .foregroundStyle(.cyan)
                Text("Material Layers")
                    .font(.headline.weight(.semibold))
                Spacer()
                if model.document.materialStack != nil {
                    Button {
                        model.setDisplayMode(.material)
                        viewport.setNeedsDisplay(viewport.bounds)
                    } label: {
                        Image(systemName: "eye.fill")
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .help("Preview material stack")
                    Menu {
                        Button(role: .destructive) {
                            model.removeMaterialStack()
                            viewport.setNeedsDisplay(viewport.bounds)
                        } label: {
                            Label("Remove Material Stack", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 24, height: 28)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                }
            }

            if let stack = model.document.materialStack {
                let terrainCandidates = model.materialTerrainOptions
                let sourceCandidates = model.materialSourceOptions
                let stackIssue = model.materialStackIssue
                terrainPicker(stack: stack, candidates: terrainCandidates)

                VStack(spacing: 8) {
                    ForEach(Array(stack.layers.enumerated()), id: \.element.id) { index, layer in
                        materialLayerRow(layer: layer, index: index,
                                         layerCount: stack.layers.count,
                                         sourceCandidates: sourceCandidates)
                    }
                }

                if stack.layers.count < 4 {
                    addOverlayMenu(stack: stack, candidates: sourceCandidates)
                }

                if let issue = stackIssue {
                    Label(issue, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Label("R/G/B/A follow the layer order. Weights are linear data.",
                          systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                materialExportSettings

                Button {
                    model.runMaterialExport()
                } label: {
                    Label(model.isExporting ? "Exporting…" : "Export Material Bundle",
                          systemImage: "shippingbox.and.arrow.backward.fill")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(Color.accentColor,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .disabled(model.isExporting || stackIssue != nil)

                if !model.exportStatus.isEmpty {
                    Text(model.exportStatus)
                        .font(.caption2)
                        .foregroundStyle(model.exportStatus.hasPrefix("export failed")
                                         ? .red : .secondary)
                        .lineLimit(2)
                }
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Blend one terrain with up to three mask or data outputs.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        model.createMaterialStack()
                        viewport.setNeedsDisplay(viewport.bounds)
                    } label: {
                        Label("Create Material Stack", systemImage: "plus.square.on.square")
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .buttonStyle(.plain)
                    .background(inspectorControlFill,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(inspectorControlStroke())
                    .disabled(model.materialTerrainOptions.isEmpty)
                }
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.025),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(Color.white.opacity(0.09), lineWidth: 1))
    }

    private func addOverlayMenu(stack: GraphMaterialStack,
                                candidates all: [GraphOutputReference]) -> some View {
        let assigned = Set(stack.layers.dropFirst().compactMap(\.source))
        let unused = all.filter { !assigned.contains($0) }
        let unusedSet = Set(unused)
        let alreadyUsed = all.filter { !unusedSet.contains($0) }
        return Menu {
            if !unused.isEmpty {
                Section("Unused outputs") {
                    ForEach(unused, id: \.self) { source in
                        addOverlayButton(source)
                    }
                }
            }
            if !alreadyUsed.isEmpty {
                Section("Already used · duplicate explicitly") {
                    ForEach(alreadyUsed, id: \.self) { source in
                        addOverlayButton(source)
                    }
                }
            }
        } label: {
            Label("Add Overlay from…", systemImage: "plus")
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 30)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .background(inspectorControlFill,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(inspectorControlStroke())
        .disabled(all.isEmpty)
    }

    private func addOverlayButton(_ source: GraphOutputReference) -> some View {
        Button {
            model.addMaterialLayer(source: source)
            viewport.setNeedsDisplay(viewport.bounds)
        } label: {
            Text(referenceLabel(source))
        }
    }

    private func terrainPicker(stack: GraphMaterialStack,
                               candidates: [GraphOutputReference]) -> some View {
        HStack(spacing: 8) {
            Text("Terrain")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Menu {
                ForEach(candidates, id: \.self) { reference in
                    Button(referenceLabel(reference)) {
                        model.setMaterialTerrain(reference)
                        viewport.setNeedsDisplay(viewport.bounds)
                    }
                }
            } label: {
                Text(candidates.contains(stack.terrain)
                     ? referenceLabel(stack.terrain)
                     : "Invalid · \(referenceLabel(stack.terrain))")
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .background(inspectorControlFill,
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
        }
    }

    private func materialLayerRow(layer: GraphMaterialLayer, index: Int,
                                  layerCount: Int,
                                  sourceCandidates: [GraphOutputReference]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(["R", "G", "B", "A"][index])
                    .font(.caption2.monospaced().weight(.bold))
                    .foregroundStyle(index == 0 ? Color.secondary : Color.cyan)
                    .frame(width: 16)
                ColorPicker("", selection: colorBinding(index: index, layer: layer),
                            supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 26)
                MaterialLayerNameEditor(model: model, index: index,
                                        layerID: layer.id, value: layer.name)

                if index > 0 {
                    Button { model.moveMaterialLayer(index: index, offset: -1) } label: {
                        Image(systemName: "chevron.up")
                    }
                    .disabled(index == 1)
                    Button { model.moveMaterialLayer(index: index, offset: 1) } label: {
                        Image(systemName: "chevron.down")
                    }
                    .disabled(index == layerCount - 1)
                    Button { model.removeMaterialLayer(index: index) } label: {
                        Image(systemName: "trash")
                    }
                    .foregroundStyle(.red.opacity(0.82))
                }
            }
            .buttonStyle(.plain)

            if index == 0 {
                Text("Base / fallback")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 24)
            } else {
                HStack(spacing: 6) {
                    Menu {
                        let assignedElsewhere = Set(model.document.materialStack?.layers
                            .enumerated().compactMap { layerIndex, candidateLayer in
                                layerIndex > 0 && layerIndex != index
                                    ? candidateLayer.source : nil
                            } ?? [])
                        let unused = Set(sourceCandidates.filter {
                            !assignedElsewhere.contains($0)
                        })
                        let prioritized = sourceCandidates.filter { unused.contains($0) } +
                            sourceCandidates.filter { !unused.contains($0) }
                        if prioritized.contains(where: { unused.contains($0) }) {
                            Section("Available outputs") {
                                ForEach(prioritized.filter { unused.contains($0) },
                                        id: \.self) { source in
                                    sourceSelectionButton(source, index: index)
                                }
                            }
                        }
                        if prioritized.contains(where: { !unused.contains($0) }) {
                            Section("Already used") {
                                ForEach(prioritized.filter { !unused.contains($0) },
                                        id: \.self) { source in
                                    sourceSelectionButton(source, index: index)
                                }
                            }
                        }
                    } label: {
                        Text(materialSourceLabel(layer.source,
                                                 candidates: sourceCandidates))
                            .font(.caption2.monospaced())
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .frame(height: 26)
                            .background(inspectorControlFill,
                                        in: RoundedRectangle(cornerRadius: 6,
                                                             style: .continuous))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)

                    Button {
                        model.inspectMaterialLayerSource(index: index)
                        viewport.setNeedsDisplay(viewport.bounds)
                    } label: {
                        Image(systemName: "scope")
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.plain)
                    .help(model.document.resolvedOutputKind(
                        nodeId: layer.source?.node ?? "",
                        output: layer.source?.output ?? "") == .mask
                        ? "Inspect source mask for editing"
                        : "Inspect scalar data source")
                    .disabled(layer.source.map {
                        !sourceCandidates.contains($0)
                    } ?? true)
                }
                .padding(.leading, 24)

                if let source = layer.source,
                   model.document.resolvedOutputKind(nodeId: source.node,
                                                     output: source.output) == .data {
                    Label("Data values are coverage. Use a Remap node for centered analysis fields.",
                          systemImage: "slider.horizontal.3")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 24)
                }
            }
        }
        .padding(8)
        .background(Color.black.opacity(0.13),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func sourceSelectionButton(_ source: GraphOutputReference,
                                       index: Int) -> some View {
        Button(referenceLabel(source)) {
            model.setMaterialLayerSource(index: index, source: source)
            viewport.setNeedsDisplay(viewport.bounds)
        }
    }

    private func materialSourceLabel(_ source: GraphOutputReference?,
                                     candidates: [GraphOutputReference]) -> String {
        guard let source else { return "Choose source" }
        return candidates.contains(source)
            ? referenceLabel(source) : "Unavailable · \(referenceLabel(source))"
    }

    private var materialExportSettings: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("BUNDLE EXPORT")
                .font(.caption2.weight(.bold))
                .tracking(0.6)
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                TextField("terrain", text: Binding(
                    get: { model.exportSettings.basename },
                    set: { model.exportSettings.basename = $0 }))
                    .textFieldStyle(.plain)
                    .font(.caption.monospaced())
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .background(inspectorControlFill,
                                in: RoundedRectangle(cornerRadius: 6,
                                                     style: .continuous))
                Button("Folder…", action: chooseFolder)
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .background(inspectorControlFill,
                                in: RoundedRectangle(cornerRadius: 6,
                                                     style: .continuous))
            }
            Text(model.exportSettings.outDir)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Stepper(value: Binding(
                get: { Int(model.exportSettings.size) },
                set: { model.exportSettings.size = UInt32(max(2, $0)) }),
                in: 64...4096, step: 64) {
                exportValueRow("Resolution", "\(model.exportSettings.size)²")
            }
            Stepper(value: Binding(
                get: { model.exportSettings.verticalScale },
                set: { model.exportSettings.verticalScale = max(0.05, $0) }),
                in: 0.05...8, step: 0.05) {
                exportValueRow("Vertical scale",
                               String(format: "%.2f", model.exportSettings.verticalScale))
            }
            Stepper(value: Binding(
                get: { Int(model.exportSettings.meshStride) },
                set: { model.exportSettings.meshStride = UInt32(max(1, $0)) }),
                in: 1...16, step: 1) {
                exportValueRow("Mesh stride", "\(model.exportSettings.meshStride)")
            }

            HStack(spacing: 10) {
                Toggle("Heightmap", isOn: Binding(
                    get: { model.exportSettings.exportHeightmap },
                    set: { model.exportSettings.exportHeightmap = $0 }))
                Menu(model.exportSettings.heightmapFormat.label) {
                    ForEach(ExportSettings.HeightmapFormat.allCases) { format in
                        Button(format.label) {
                            model.exportSettings.heightmapFormat = format
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .disabled(!model.exportSettings.exportHeightmap)
                Spacer()
                Toggle("OBJ", isOn: Binding(
                    get: { model.exportSettings.exportMesh },
                    set: { model.exportSettings.exportMesh = $0 }))
            }
            .toggleStyle(.checkbox)
            .font(.caption)
        }
    }

    private func exportValueRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).monospacedDigit().foregroundStyle(.secondary)
        }
        .font(.caption)
    }

    private func colorBinding(index: Int, layer: GraphMaterialLayer) -> Binding<Color> {
        Binding(
            get: { color(layer.previewColorSRGB) },
            set: { newColor in
                guard let converted = NSColor(newColor).usingColorSpace(.sRGB) else { return }
                model.setMaterialLayerColor(index: index,
                    color: [Double(converted.redComponent),
                            Double(converted.greenComponent),
                            Double(converted.blueComponent)])
                viewport.setNeedsDisplay(viewport.bounds)
            })
    }

    private func color(_ components: [Double]) -> Color {
        guard components.count == 3 else { return .gray }
        return Color(.sRGB, red: components[0], green: components[1],
                     blue: components[2], opacity: 1)
    }

    private func referenceLabel(_ reference: GraphOutputReference) -> String {
        "\(reference.node).\(reference.output)"
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.exportSettings.outDir = url.path
    }
}

private struct MaterialLayerNameEditor: View {
    @ObservedObject var model: TerrainModel
    let index: Int
    let layerID: String
    let value: String
    @State private var draft: String
    @FocusState private var focused: Bool

    init(model: TerrainModel, index: Int, layerID: String, value: String) {
        self.model = model
        self.index = index
        self.layerID = layerID
        self.value = value
        _draft = State(initialValue: value)
    }

    var body: some View {
        TextField("Layer name", text: $draft)
            .textFieldStyle(.plain)
            .font(.caption.weight(.semibold))
            .focused($focused)
            .onSubmit(commit)
            .onChange(of: focused) { wasFocused, isFocused in
                if wasFocused && !isFocused { commit() }
            }
            .onChange(of: value) { _, newValue in
                // Undo/redo and external document reload are authoritative even
                // while the field is focused; retaining an old draft would write
                // the reverted name back on the next blur.
                draft = newValue
            }
            .id(layerID)
    }

    private func commit() {
        let clean = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty {
            draft = value
        } else {
            model.setMaterialLayerName(index: index, name: clean)
            draft = clean
        }
    }
}
