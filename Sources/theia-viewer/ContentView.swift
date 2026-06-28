import MetalKit
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct TerrainViewport: NSViewRepresentable {
    let view: TerrainMTKView

    func makeNSView(context: Context) -> TerrainMTKView { view }
    func updateNSView(_ nsView: TerrainMTKView, context: Context) {}
}

struct ContentView: View {
    @ObservedObject var model: TerrainModel
    let viewport: TerrainMTKView

    var body: some View {
        HSplitView {
            VSplitView {
                TerrainViewport(view: viewport)
                    .frame(minWidth: 560, minHeight: 260, idealHeight: 360)

                NodeEditorCanvas(model: model, viewport: viewport)
                    .frame(minWidth: 560, minHeight: 320, idealHeight: 460)
            }
            .frame(minWidth: 560, minHeight: 680)

            InspectorPanel(model: model, viewport: viewport)
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 380)
        }
    }
}

struct InspectorPanel: View {
    @ObservedObject var model: TerrainModel
    let viewport: TerrainMTKView

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Inspector")
                    .font(.headline)
                Spacer()
                if !model.lastStats.isEmpty {
                    Text(model.lastStats)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    GraphActions(model: model, viewport: viewport)
                        .padding(.horizontal, 14)

                    Divider()
                        .padding(.horizontal, 14)

                    ViewportControls(model: model, viewport: viewport)
                        .padding(.horizontal, 14)

                    Divider()
                        .padding(.horizontal, 14)

                    NodeParameterInspector(model: model, viewport: viewport)
                        .padding(.horizontal, 14)
                }
                .padding(.vertical, 14)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

struct GraphActions: View {
    @ObservedObject var model: TerrainModel
    let viewport: TerrainMTKView

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Graph")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    openDocument()
                    viewport.setNeedsDisplay(viewport.bounds)
                } label: {
                    Label("Load", systemImage: "folder")
                }
                .buttonStyle(.borderless)
                Button {
                    saveDocument()
                    viewport.setNeedsDisplay(viewport.bounds)
                } label: {
                    Label("Save", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderless)
            }

            HStack {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(model.isDirty ? .orange : .secondary)
                Spacer()
            }

            if let nodeId = model.selectedNodeId,
               let node = model.document.node(id: nodeId) {
                HStack {
                    Text("selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(node.id) / \(node.type)")
                        .font(.caption.monospaced())
                        .lineLimit(1)
                    Spacer()
                }
            } else if model.selectedConnectionId != nil {
                HStack {
                    Text("edge selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        model.deleteSelection()
                        viewport.setNeedsDisplay(viewport.bounds)
                    } label: {
                        Label("Disconnect", systemImage: "xmark")
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    private var statusText: String {
        let state = model.isDirty ? "unsaved changes" :
            (model.saveStatus.isEmpty ? "saved in memory" : model.saveStatus)
        guard let path = model.graphPath else { return state }
        return "\(state) - \(URL(fileURLWithPath: path).lastPathComponent)"
    }

    private func saveDocument() {
        if let _ = model.graphPath {
            _ = model.save()
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "terrain-graph.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = model.save(to: url.path)
    }

    private func openDocument() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.load(from: url.path)
    }
}

struct NodeParameterInspector: View {
    @ObservedObject var model: TerrainModel
    let viewport: TerrainMTKView

    var visibleNodes: [GraphNodeInfo] {
        if let selected = model.selectedNodeId,
           let node = model.nodes.first(where: { $0.id == selected }) {
            return [node]
        }
        return []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(model.selectedNodeId == nil ? "Parameters" : "Selected Node")
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }

            if visibleNodes.isEmpty {
                Text(model.document.nodes.isEmpty ? "No nodes" : "No node selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(visibleNodes) { node in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(node.id)
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(node.type)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if node.params.isEmpty {
                        Text("No parameters")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    ForEach(node.params) { param in
                        ParameterSlider(param: param) { value in
                            model.apply(nodeId: param.nodeId,
                                        param: param.name,
                                        value: value)
                            viewport.setNeedsDisplay(viewport.bounds)
                        }
                    }
                }
            }
        }
    }
}

struct ViewportControls: View {
    @ObservedObject var model: TerrainModel
    let viewport: TerrainMTKView

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Viewport")
                    .font(.subheadline.weight(.semibold))
                Text(model.activeDisplayModeLabel())
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.resetCamera()
                    redraw()
                } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
            }

            HStack {
                Text("display")
                    .font(.caption)
                Spacer()
                Picker("", selection: Binding(
                    get: { model.displayMode },
                    set: { mode in
                        model.setDisplayMode(mode)
                        redraw()
                    })) {
                    ForEach(ViewportDisplayMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 130)
            }

            HStack {
                Text("material")
                    .font(.caption)
                Spacer()
                Picker("", selection: Binding(
                    get: { model.materialPreset },
                    set: { preset in
                        model.setMaterialPreset(preset)
                        redraw()
                    })) {
                    ForEach(MaterialPreset.allCases) { preset in
                        Text(preset.label).tag(preset)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 130)
            }

            SettingSlider(title: "mask opacity",
                          value: Binding(
                            get: { model.maskOpacity },
                            set: { value in
                                model.setMaskOpacity(value)
                                redraw()
                            }),
                          range: 0...1,
                          step: 0.01,
                          precision: 2)

            SettingSlider(title: "light azimuth",
                          value: setting(\.lightAzimuthDegrees),
                          range: -180...180,
                          step: 1,
                          precision: 0)

            SettingSlider(title: "light elevation",
                          value: setting(\.lightElevationDegrees),
                          range: 5...90,
                          step: 1,
                          precision: 0)

            Toggle("wireframe", isOn: Binding(
                get: { model.wireframeEnabled },
                set: { enabled in
                    model.wireframeEnabled = enabled
                    model.applyViewportSettings()
                    redraw()
                }))
                .font(.caption)
        }
    }

    private func setting(_ keyPath: ReferenceWritableKeyPath<TerrainModel, Double>)
        -> Binding<Double> {
        Binding(
            get: { model[keyPath: keyPath] },
            set: { value in
                model[keyPath: keyPath] = value
                model.applyViewportSettings()
                redraw()
            })
    }

    private func redraw() {
        viewport.setNeedsDisplay(viewport.bounds)
    }
}

struct SettingSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let precision: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption)
                Spacer()
                Text(String(format: "%.\(precision)f", value))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step)
        }
    }
}

struct ParameterSlider: View {
    let param: GraphParameter
    let onChange: (Double) -> Void

    @State private var value: Double
    private let config: SliderConfig

    init(param: GraphParameter, onChange: @escaping (Double) -> Void) {
        self.param = param
        self.onChange = onChange
        _value = State(initialValue: param.value)
        config = SliderConfig.forParam(param)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(param.name)
                    .font(.caption)
                Spacer()
                if param.nodeType == "blend", param.name == "mode" {
                    Text(blendModeName(Int(round(value))))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text(config.format(value))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if param.nodeType == "blend", param.name == "mode" {
                Picker("", selection: Binding(
                    get: { Int(round(value)) },
                    set: { mode in
                        value = Double(mode)
                        onChange(value)
                    })) {
                        ForEach(0..<blendModeNames.count, id: \.self) { mode in
                            Text(blendModeNames[mode]).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
            } else {
                Slider(value: $value, in: config.range, step: config.step) { editing in
                    if !editing {
                        onChange(value)
                    }
                }
            }
        }
        .onChange(of: param.value) { _, newValue in
            value = newValue
        }
    }

    private var blendModeNames: [String] {
        ["mix", "add", "multiply", "max", "min", "screen"]
    }

    private func blendModeName(_ mode: Int) -> String {
        guard blendModeNames.indices.contains(mode) else { return "mix" }
        return blendModeNames[mode]
    }
}

struct SliderConfig {
    let range: ClosedRange<Double>
    let step: Double
    let precision: Int

    func format(_ value: Double) -> String {
        String(format: "%.\(precision)f", value)
    }

    static func forParam(_ param: GraphParameter) -> SliderConfig {
        let name = param.name
        let value = param.value
        switch name {
        case "seed":
            return SliderConfig(range: 0...9999, step: 1, precision: 0)
        case "octaves":
            return SliderConfig(range: 1...12, step: 1, precision: 0)
        case "iterations":
            return SliderConfig(range: 1...300, step: 1, precision: 0)
        case "frequency":
            return SliderConfig(range: 0.1...32, step: 0.1, precision: 1)
        case "lacunarity":
            return SliderConfig(range: 1...4, step: 0.05, precision: 2)
        case "gain", "t", "rain", "evaporation", "sedimentCapacity",
             "suspension", "deposition", "minTilt", "opacity", "amount":
            return SliderConfig(range: 0...1, step: 0.01, precision: 2)
        case "strength":
            if param.nodeType == "warp" {
                return SliderConfig(range: 0...0.35, step: 0.005, precision: 3)
            }
            return SliderConfig(range: 0...1, step: 0.01, precision: 2)
        case "mode":
            return SliderConfig(range: 0...5, step: 1, precision: 0)
        case "low", "high":
            if param.nodeType == "slopemask" {
                return SliderConfig(range: 0...90, step: 1, precision: 0)
            }
            return SliderConfig(range: 0...1, step: 0.01, precision: 2)
        case "min", "max", "inLow", "inHigh", "outLow", "outHigh", "clamp":
            return SliderConfig(range: 0...1, step: 0.01, precision: 2)
        case "gamma":
            return SliderConfig(range: 0.1...4, step: 0.05, precision: 2)
        case "scale":
            return SliderConfig(range: -4...4, step: 0.01, precision: 2)
        case "bias":
            return SliderConfig(range: -1...1, step: 0.01, precision: 2)
        case "radius":
            return SliderConfig(range: 0...16, step: 1, precision: 0)
        case "steps":
            return SliderConfig(range: 2...32, step: 1, precision: 0)
        case "sharpness", "ridgeSharpness":
            return SliderConfig(range: 0.1...10, step: 0.1, precision: 1)
        case "talusAngle":
            return SliderConfig(range: 1...60, step: 0.5, precision: 1)
        case "heightScale":
            if param.nodeType == "perlin" || param.nodeType == "ridged" {
                return SliderConfig(range: 0...2, step: 0.05, precision: 2)
            }
            if param.nodeType == "slopemask" {
                return SliderConfig(range: 0...8, step: 0.05, precision: 2)
            }
            return SliderConfig(range: 1...160, step: 1, precision: 0)
        case "dt":
            return SliderConfig(range: 0.001...0.1, step: 0.001, precision: 3)
        case "gravity":
            return SliderConfig(range: 0...20, step: 0.1, precision: 1)
        case "pipeArea", "pipeLength", "cellSize":
            return SliderConfig(range: 0.1...4, step: 0.1, precision: 1)
        default:
            let span = max(1, abs(value) * 2)
            return SliderConfig(range: (value - span)...(value + span),
                                step: span / 100,
                                precision: 2)
        }
    }
}
