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
                }
            }

            if let stack = model.document.materialStack {
                terrainPicker(stack: stack)

                VStack(spacing: 8) {
                    ForEach(Array(stack.layers.enumerated()), id: \.element.id) { index, layer in
                        materialLayerRow(layer: layer, index: index,
                                         layerCount: stack.layers.count)
                    }
                }

                if stack.layers.count < 4 {
                    Button {
                        model.addMaterialLayer()
                        viewport.setNeedsDisplay(viewport.bounds)
                    } label: {
                        Label("Add Overlay", systemImage: "plus")
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 30)
                    }
                    .buttonStyle(.plain)
                    .background(inspectorControlFill,
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(inspectorControlStroke())
                    .disabled(model.document.materialSourceCandidates().isEmpty)
                }

                if let issue = model.document.materialStackValidationMessage() {
                    Label(issue, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Label("R/G/B/A follow the layer order. Weights are linear data.",
                          systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
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
                    HStack(spacing: 14) {
                        Toggle("Heightmap", isOn: Binding(
                            get: { model.exportSettings.exportHeightmap },
                            set: { model.exportSettings.exportHeightmap = $0 }))
                        Toggle("OBJ", isOn: Binding(
                            get: { model.exportSettings.exportMesh },
                            set: { model.exportSettings.exportMesh = $0 }))
                    }
                    .toggleStyle(.checkbox)
                    .font(.caption)
                }

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
                .disabled(model.isExporting ||
                          model.document.materialStackValidationMessage() != nil)

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
                    .disabled(model.document.materialTerrainCandidates().isEmpty)
                }
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.025),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(Color.white.opacity(0.09), lineWidth: 1))
    }

    private func terrainPicker(stack: GraphMaterialStack) -> some View {
        HStack(spacing: 8) {
            Text("Terrain")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Menu {
                ForEach(model.document.materialTerrainCandidates(), id: \.self) { reference in
                    Button(referenceLabel(reference)) {
                        model.setMaterialTerrain(reference)
                        viewport.setNeedsDisplay(viewport.bounds)
                    }
                }
            } label: {
                Text(referenceLabel(stack.terrain))
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
                                  layerCount: Int) -> some View {
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
                TextField("Layer name", text: Binding(
                    get: { layer.name },
                    set: { model.setMaterialLayerName(index: index, name: $0) }))
                    .textFieldStyle(.plain)
                    .font(.caption.weight(.semibold))

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
                        ForEach(model.document.materialSourceCandidates(), id: \.self) { source in
                            Button(referenceLabel(source)) {
                                model.setMaterialLayerSource(index: index, source: source)
                                viewport.setNeedsDisplay(viewport.bounds)
                            }
                        }
                    } label: {
                        Text(layer.source.map(referenceLabel) ?? "Choose source")
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
                    .help("Inspect scalar source for mask editing")
                }
                .padding(.leading, 24)
            }
        }
        .padding(8)
        .background(Color.black.opacity(0.13),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
