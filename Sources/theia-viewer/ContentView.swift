import MetalKit
import SwiftUI

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
            TerrainViewport(view: viewport)
                .frame(minWidth: 520, minHeight: 420)

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
                Text("Parameters")
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
                    ViewportControls(model: model, viewport: viewport)
                        .padding(.horizontal, 14)

                    Divider()
                        .padding(.horizontal, 14)

                    ForEach(model.nodes) { node in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(node.id)
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(node.type)
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
                        .padding(.horizontal, 14)
                    }
                }
                .padding(.vertical, 14)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
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
                Spacer()
                Button {
                    model.resetCamera()
                    redraw()
                } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
            }

            SettingSlider(title: "height",
                          value: setting(\.heightExaggeration),
                          range: 0.05...2.0,
                          step: 0.05,
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
        config = SliderConfig.forParam(name: param.name, value: param.value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(param.name)
                    .font(.caption)
                Spacer()
                Text(config.format(value))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: config.range, step: config.step) { editing in
                if !editing {
                    onChange(value)
                }
            }
        }
        .onChange(of: param.value) { _, newValue in
            value = newValue
        }
    }
}

struct SliderConfig {
    let range: ClosedRange<Double>
    let step: Double
    let precision: Int

    func format(_ value: Double) -> String {
        String(format: "%.\(precision)f", value)
    }

    static func forParam(name: String, value: Double) -> SliderConfig {
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
             "suspension", "deposition", "strength", "minTilt":
            return SliderConfig(range: 0...1, step: 0.01, precision: 2)
        case "scale":
            return SliderConfig(range: -4...4, step: 0.01, precision: 2)
        case "bias":
            return SliderConfig(range: -1...1, step: 0.01, precision: 2)
        case "steps":
            return SliderConfig(range: 2...32, step: 1, precision: 0)
        case "sharpness":
            return SliderConfig(range: 0.1...10, step: 0.1, precision: 1)
        case "talusAngle":
            return SliderConfig(range: 1...60, step: 0.5, precision: 1)
        case "heightScale":
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
