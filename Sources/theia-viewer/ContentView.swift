import MetalKit
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import simd

private let topToolbarHeight: CGFloat = 44
private let topToolbarDividerColor = Color.white.opacity(0.08)

struct TerrainViewport: NSViewRepresentable {
    let view: TerrainMTKView

    func makeNSView(context: Context) -> TerrainMTKView { view }
    func updateNSView(_ nsView: TerrainMTKView, context: Context) {}
}

struct ContentView: View {
    @ObservedObject var model: TerrainModel
    let viewport: TerrainMTKView

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            HSplitView {
                VSplitView {
                    ViewportSurface(model: model, viewport: viewport)
                        .frame(minWidth: 560, minHeight: 360, idealHeight: 720)
                        .layoutPriority(3)

                    NodeEditorCanvas(model: model, viewport: viewport)
                        .frame(minWidth: 560, minHeight: 220, idealHeight: 260)
                        .layoutPriority(1)
                }
                .frame(minWidth: 560, minHeight: 680)

                InspectorPanel(model: model, viewport: viewport)
                    .frame(minWidth: 280, idealWidth: 320, maxWidth: 380)
            }

            StatusBadge(model: model)
                .padding(.trailing, 14)
                .padding(.bottom, 12)
        }
    }
}

struct ViewportSurface: View {
    @ObservedObject var model: TerrainModel
    let viewport: TerrainMTKView
    @State private var toolbarHint: String?
    @State private var showingViewportSettings = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            TerrainViewport(view: viewport)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 0) {
                viewportToolbar
                Spacer()
            }

            floatingViewportMenus
                .padding(.top, 54)
                .padding(.leading, 12)

            AxisGizmo(model: model, viewport: viewport)
                .frame(width: 76, height: 76)
                .padding(.top, 52)
                .padding(.trailing, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: .topTrailing)
        }
    }

    private var floatingViewportMenus: some View {
        HStack(spacing: 8) {
            viewProjectionMenu
            displayModeMenu
            materialPresetMenu
            viewportSettingsButton
        }
    }

    private var viewProjectionMenu: some View {
        Menu {
            menuCheckButton("Perspective",
                            selected: model.viewportProjection == .perspective,
                            action: {
                                model.setViewportProjection(.perspective)
                                redraw()
                            })
            menuCheckButton("Orthographic",
                            selected: model.viewportProjection == .orthographic,
                            action: {
                                model.setViewportProjection(.orthographic)
                                redraw()
                            })

            Divider()

            Button("Reset Camera") {
                model.resetCamera()
                redraw()
            }
            Button("Top") {
                model.setCameraPreset(.top)
                redraw()
            }
        } label: {
            HStack(spacing: 6) {
                Text(model.viewportProjection.label)
                    .font(.system(size: 12, weight: .semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .opacity(0.72)
            }
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.black.opacity(0.42),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .help("Projection and camera options")
        }
        .buttonStyle(.plain)
        .onHover { setToolbarHint("Projection and camera options", hovering: $0) }
    }

    private var displayModeMenu: some View {
        Menu {
            ForEach(ViewportDisplayMode.allCases, id: \.self) { mode in
                menuCheckButton(mode.label,
                                selected: model.displayMode == mode,
                                action: {
                                    model.setDisplayMode(mode)
                                    redraw()
                                })
            }
        } label: {
            Image(systemName: "circle.lefthalf.filled")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.88))
                .frame(width: 30, height: 30)
                .background(Color.black.opacity(0.42),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .help("Display mode")
        }
        .buttonStyle(.plain)
        .onHover { setToolbarHint("Display mode: \(model.displayMode.label)", hovering: $0) }
    }

    private var materialPresetMenu: some View {
        Menu {
            ForEach(MaterialPreset.allCases, id: \.self) { preset in
                menuCheckButton(preset.label,
                                selected: model.materialPreset == preset,
                                action: {
                                    model.setMaterialPreset(preset)
                                    redraw()
                                })
            }
        } label: {
            Circle()
                .fill(materialSwatch(model.materialPreset))
                .overlay(Circle().stroke(Color.white.opacity(0.28), lineWidth: 1))
                .frame(width: 15, height: 15)
                .frame(width: 30, height: 30)
                .background(Color.black.opacity(0.42),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .help("Material preset")
        }
        .buttonStyle(.plain)
        .onHover { setToolbarHint("Material: \(model.materialPreset.label)", hovering: $0) }
    }

    private var viewportSettingsButton: some View {
        Button {
            showingViewportSettings.toggle()
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.88))
                .frame(width: 30, height: 30)
                .background(Color.black.opacity(0.42),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .help("Viewport settings")
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingViewportSettings, arrowEdge: .top) {
            ViewportSettingsPopover(model: model, viewport: viewport)
                .frame(width: 270)
                .padding(14)
        }
        .onHover { setToolbarHint("Viewport settings", hovering: $0) }
    }

    private var viewportToolbar: some View {
        HStack(spacing: 5) {
            viewportButton(systemImage: "folder",
                           help: "Load graph") {
                openDocument()
                redraw()
            }
            viewportButton(systemImage: "square.and.arrow.down",
                           help: "Save graph") {
                saveDocument()
                redraw()
            }

            toolbarDivider

            viewportButton(systemImage: "viewfinder",
                           help: "Reset camera (F)") {
                model.resetCamera()
                redraw()
            }
            viewportButton(systemImage: "arrow.triangle.2.circlepath",
                           help: "Orbit tool (O): left drag orbits the camera.",
                           active: model.viewportTool == .orbit) {
                model.setViewportTool(.orbit)
                redraw()
            }
            viewportButton(systemImage: "hand.draw",
                           help: "Pan tool (H): left drag pans the camera.",
                           active: model.viewportTool == .pan) {
                model.setViewportTool(.pan)
                redraw()
            }
            viewportButton(systemImage: "magnifyingglass",
                           help: "Zoom tool (Z): left drag vertically zooms the camera.",
                           active: model.viewportTool == .zoom) {
                model.setViewportTool(.zoom)
                redraw()
            }

            toolbarDivider

            viewportButton(systemImage: "square.grid.3x3",
                           help: "Toggle grid",
                           active: model.gridVisible) {
                model.setGridVisible(!model.gridVisible)
                redraw()
            }
            viewportButton(systemImage: "arrow.up.and.down.and.arrow.left.and.right",
                           help: "Toggle axes",
                           active: model.axisVisible) {
                model.setAxisVisible(!model.axisVisible)
                redraw()
            }
            viewportButton(systemImage: "cube.transparent",
                           help: "Toggle wireframe",
                           active: model.wireframeEnabled) {
                model.wireframeEnabled.toggle()
                model.applyViewportSettings()
                redraw()
            }

            if let toolbarHint {
                Text(toolbarHint)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.58))
                    .lineLimit(1)
                    .padding(.leading, 8)
                    .transition(.opacity)
            }

            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(height: topToolbarHeight)
        .background(Color(red: 0.115, green: 0.12, blue: 0.13).opacity(0.96))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(topToolbarDividerColor)
                .frame(height: 1)
        }
    }

    private func viewportButton(systemImage: String, help: String,
                                active: Bool = false,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
                .background(active ? Color.accentColor.opacity(0.35) : Color.white.opacity(0.07),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(active ? Color.accentColor : Color.white.opacity(0.86))
        .accessibilityLabel(Text(help))
        .onHover { setToolbarHint(help, hovering: $0) }
        .help(help)
    }

    private func menuCheckButton(_ title: String, selected: Bool,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                if selected {
                    Image(systemName: "checkmark")
                }
                Text(title)
            }
        }
    }

    private func materialSwatch(_ preset: MaterialPreset) -> Color {
        switch preset {
        case .natural:
            return Color(red: 0.36, green: 0.62, blue: 0.36)
        case .alpine:
            return Color(red: 0.78, green: 0.86, blue: 0.92)
        case .arid:
            return Color(red: 0.78, green: 0.58, blue: 0.34)
        case .analysis:
            return Color(red: 0.26, green: 0.55, blue: 0.95)
        }
    }

    private func setToolbarHint(_ hint: String, hovering: Bool) {
        if hovering {
            toolbarHint = hint
        } else if toolbarHint == hint {
            toolbarHint = nil
        }
    }

    private var toolbarDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(width: 1, height: 26)
            .padding(.horizontal, 5)
    }

    private func redraw() {
        viewport.setNeedsDisplay(viewport.bounds)
    }

    private func saveDocument() {
        if model.graphPath != nil {
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

struct AxisGizmo: View {
    @ObservedObject var model: TerrainModel
    let viewport: TerrainMTKView
    private let center = CGPoint(x: 38, y: 40)

    var body: some View {
        let revision = model.viewportCameraRevision
        let xAxis = axisLayout(axis: SIMD3<Float>(1, 0, 0), revision: revision)
        let yAxis = axisLayout(axis: SIMD3<Float>(0, 0, 1), revision: revision)
        let zAxis = axisLayout(axis: SIMD3<Float>(0, 1, 0), revision: revision)
        ZStack {
            gizmoLine(from: center, to: xAxis.negative.point, color: .red.opacity(0.28))
            gizmoLine(from: center, to: yAxis.negative.point, color: .green.opacity(0.28))
            gizmoLine(from: center, to: zAxis.negative.point, color: .blue.opacity(0.28))
            gizmoLine(from: center, to: xAxis.positive.point, color: .red.opacity(0.9))
            gizmoLine(from: center, to: yAxis.positive.point, color: .green.opacity(0.9))
            gizmoLine(from: center, to: zAxis.positive.point, color: .blue.opacity(0.9))
            gizmoHub()
            gizmoDot(xAxis.negative.point, color: dotColor(.red, depth: xAxis.negative.depth), label: "",
                     help: "View from -X", preset: .left)
            gizmoDot(yAxis.negative.point, color: dotColor(.green, depth: yAxis.negative.depth), label: "",
                     help: "View from -Y", preset: .back)
            gizmoDot(zAxis.negative.point, color: dotColor(.blue, depth: zAxis.negative.depth), label: "",
                     help: "Bottom view from -Z", preset: .bottom)
            gizmoDot(xAxis.positive.point, color: dotColor(.red, depth: xAxis.positive.depth), label: "X",
                     help: "View from +X", preset: .right)
            gizmoDot(yAxis.positive.point, color: dotColor(.green, depth: yAxis.positive.depth), label: "Y",
                     help: "View from +Y", preset: .front)
            gizmoDot(zAxis.positive.point, color: dotColor(.blue, depth: zAxis.positive.depth), label: "Z",
                     help: "Top view from +Z", preset: .top)
        }
    }

    private func gizmoLine(from: CGPoint, to: CGPoint, color: Color) -> some View {
        Path { p in
            p.move(to: from)
            p.addLine(to: to)
        }
        .stroke(color, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
    }

    private func gizmoHub() -> some View {
        Button {
            model.resetCamera()
            redraw()
        } label: {
            Circle()
                .fill(Color.white.opacity(0.22))
                .overlay(Circle().stroke(Color.white.opacity(0.36), lineWidth: 1))
                .frame(width: 13, height: 13)
        }
        .buttonStyle(.plain)
        .help("Reset camera")
        .position(center)
    }

    private func gizmoDot(_ point: CGPoint, color: Color, label: String,
                          help: String, preset: CameraPreset) -> some View {
        Button {
            model.setCameraPreset(preset)
            redraw()
        } label: {
            Circle()
                .fill(color)
                .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
                .frame(width: 18, height: 18)
                .overlay {
                    if !label.isEmpty {
                        Text(label)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.black.opacity(0.78))
                    }
                }
        }
        .buttonStyle(.plain)
        .help(help)
        .position(point)
    }

    private typealias AxisEndpoint = (point: CGPoint, depth: CGFloat)

    private func axisLayout(axis: SIMD3<Float>,
                            revision: UInt64) -> (positive: AxisEndpoint,
                                                   negative: AxisEndpoint) {
        _ = revision
        return (axisEndpoint(axis), axisEndpoint(-axis))
    }

    private func axisEndpoint(_ axis: SIMD3<Float>) -> AxisEndpoint {
        let b = model.renderer.camera.basis()
        let x = CGFloat(dot(axis, b.right))
        let y = CGFloat(-dot(axis, b.up))
        let depth = CGFloat(dot(axis, b.forward))
        let radius: CGFloat = 29
        let point = CGPoint(x: center.x + x * radius,
                            y: center.y + y * radius)
        return (point, depth)
    }

    private func dotColor(_ color: Color, depth: CGFloat) -> Color {
        color.opacity(depth >= 0 ? 0.98 : 0.48)
    }

    private func redraw() {
        viewport.setNeedsDisplay(viewport.bounds)
    }
}

struct StatusBadge: View {
    @ObservedObject var model: TerrainModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            VStack(alignment: .trailing, spacing: 4) {
                Label(model.isDirty ? "unsaved" : "saved",
                      systemImage: model.isDirty
                        ? "exclamationmark.circle.fill"
                        : "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(model.isDirty ? .red : .green)

                Text(savedTimestamp(relativeTo: timeline.date))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.48),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .allowsHitTesting(false)
        }
    }

    private func savedTimestamp(relativeTo now: Date) -> String {
        guard let savedAt = model.lastSavedAt else { return "Not saved yet" }
        let seconds = max(0, Int(now.timeIntervalSince(savedAt)))
        if seconds < 60 { return "Just now" }
        let minutes = seconds / 60
        if minutes <= 15 {
            return "\(minutes) minute\(minutes == 1 ? "" : "s") ago"
        }
        if seconds < 24 * 60 * 60 {
            return savedAt.formatted(.dateTime.hour().minute())
        }
        return savedAt.formatted(.dateTime.weekday(.abbreviated).hour().minute())
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
                inspectorContext
            }
            .padding(.horizontal, 14)
            .frame(height: topToolbarHeight)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(topToolbarDividerColor)
                    .frame(height: 1)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if selectedNodeType == "export" {
                        ExportControls(model: model)
                            .padding(.horizontal, 14)

                        Divider()
                            .padding(.horizontal, 14)
                    }

                    NodeParameterInspector(model: model, viewport: viewport)
                        .padding(.horizontal, 14)
                }
                .padding(.vertical, 14)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var selectedNodeType: String? {
        guard let id = model.selectedNodeId else { return nil }
        return model.document.node(id: id)?.type
    }

    @ViewBuilder
    private var inspectorContext: some View {
        if let id = model.selectedNodeId,
           let node = model.document.node(id: id) {
            Text("\(node.id) / \(node.type)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else if model.selectedConnectionId != nil {
            Text("edge selected")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text(model.document.nodes.isEmpty ? "empty graph" : "no selection")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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

struct ExportControls: View {
    @ObservedObject var model: TerrainModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Export")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    model.runExport()
                } label: {
                    Label(model.isExporting ? "Exporting" : "Export",
                          systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderless)
                .disabled(model.isExporting)
            }

            HStack {
                Text("folder")
                    .font(.caption)
                Spacer()
                Button {
                    chooseFolder()
                } label: {
                    Label("Choose", systemImage: "folder")
                }
                .buttonStyle(.borderless)
            }
            Text(model.exportSettings.outDir)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)

            TextField("basename", text: Binding(
                get: { model.exportSettings.basename },
                set: { model.exportSettings.basename = $0 }))
                .textFieldStyle(.roundedBorder)
                .font(.caption)

            SettingSlider(title: "size",
                          value: Binding(
                            get: { Double(model.exportSettings.size) },
                            set: { model.exportSettings.size = UInt32(max(2, $0.rounded())) }),
                          range: 64...4096,
                          step: 64,
                          precision: 0)

            SettingSlider(title: "vertical scale",
                          value: Binding(
                            get: { model.exportSettings.verticalScale },
                            set: { model.exportSettings.verticalScale = max(0.001, $0) }),
                          range: 0.05...8,
                          step: 0.05,
                          precision: 2)

            SettingSlider(title: "mesh stride",
                          value: Binding(
                            get: { Double(model.exportSettings.meshStride) },
                            set: { model.exportSettings.meshStride = UInt32(max(1, $0.rounded())) }),
                          range: 1...16,
                          step: 1,
                          precision: 0)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())],
                      alignment: .leading, spacing: 6) {
                exportToggle("height", \.exportHeight)
                exportToggle("pfm", \.exportPFM)
                exportToggle("normal", \.exportNormal)
                exportToggle("slope", \.exportSlope)
                exportToggle("mask", \.exportMask)
                exportToggle("obj", \.exportOBJ)
            }

            if !model.exportStatus.isEmpty {
                Text(model.exportStatus)
                    .font(.caption)
                    .foregroundStyle(model.exportStatus.hasPrefix("export failed") ? .red : .secondary)
            }
        }
    }

    private func exportToggle(_ title: String,
                              _ keyPath: WritableKeyPath<ExportSettings, Bool>) -> some View {
        Toggle(title, isOn: Binding(
            get: { model.exportSettings[keyPath: keyPath] },
            set: { model.exportSettings[keyPath: keyPath] = $0 }))
            .font(.caption)
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

struct ViewportSettingsPopover: View {
    @ObservedObject var model: TerrainModel
    let viewport: TerrainMTKView

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
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
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .help("Reset camera")
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

            if model.canEditActiveMask {
                HStack {
                    Toggle(isOn: Binding(
                        get: { model.maskBrushEnabled },
                        set: { enabled in
                            model.maskBrushEnabled = enabled
                            redraw()
                        })) {
                        Label("Erase", systemImage: "eraser")
                    }
                    .font(.caption)
                    Spacer()
                    Button {
                        model.clearActiveMaskErase()
                        redraw()
                    } label: {
                        Label("Clear", systemImage: "xmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.activeMaskEraseCount == 0)
                }

                SettingSlider(title: "brush",
                              value: Binding(
                                get: { model.maskBrushRadius },
                                set: { model.maskBrushRadius = min(max($0, 0.005), 0.12) }),
                              range: 0.005...0.12,
                              step: 0.005,
                              precision: 3)
            }

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

            if model.canEditActiveMask {
                HStack {
                    Toggle(isOn: Binding(
                        get: { model.maskBrushEnabled },
                        set: { enabled in
                            model.maskBrushEnabled = enabled
                            redraw()
                        })) {
                        Label("Erase", systemImage: "eraser")
                    }
                    .font(.caption)
                    Spacer()
                    Button {
                        model.clearActiveMaskErase()
                        redraw()
                    } label: {
                        Label("Clear", systemImage: "xmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.activeMaskEraseCount == 0)
                }

                SettingSlider(title: "brush",
                              value: Binding(
                                get: { model.maskBrushRadius },
                                set: { model.maskBrushRadius = min(max($0, 0.005), 0.12) }),
                              range: 0.005...0.12,
                              step: 0.005,
                              precision: 3)
            }

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
        case "particles":
            return SliderConfig(range: 100...50000, step: 100, precision: 0)
        case "maxAge":
            return SliderConfig(range: 1...300, step: 1, precision: 0)
        case "frequency":
            return SliderConfig(range: 0.1...32, step: 0.1, precision: 1)
        case "lacunarity":
            return SliderConfig(range: 1...4, step: 0.05, precision: 2)
        case "gain", "t", "rain", "sedimentCapacity",
             "suspension", "minTilt", "opacity", "amount",
             "water", "depth", "downcutting":
            return SliderConfig(range: 0...1, step: 0.01, precision: 2)
        case "deposition":
            return SliderConfig(range: 0...0.6, step: 0.01, precision: 2)
        case "evaporation":
            return SliderConfig(range: 0...0.4, step: 0.005, precision: 3)
        case "width":
            if param.nodeType == "river" {
                return SliderConfig(range: 0.25...16, step: 0.25, precision: 2)
            }
            return SliderConfig(range: 0...16, step: 0.25, precision: 2)
        case "strength":
            if param.nodeType == "warp" {
                return SliderConfig(range: 0...0.35, step: 0.005, precision: 3)
            }
            return SliderConfig(range: 0...1, step: 0.01, precision: 2)
        case "mode":
            return SliderConfig(range: 0...5, step: 1, precision: 0)
        case "renderSurface":
            return SliderConfig(range: 0...1, step: 1, precision: 0)
        case "low", "high":
            if param.nodeType == "slopemask" {
                return SliderConfig(range: 0...90, step: 1, precision: 0)
            }
            return SliderConfig(range: 0...1, step: 0.01, precision: 2)
        case "min", "max", "inLow", "inHigh", "outLow", "outHigh", "clamp":
            return SliderConfig(range: 0...1, step: 0.01, precision: 2)
        case "gamma":
            return SliderConfig(range: 0.1...4, step: 0.05, precision: 2)
        case "entrainment":
            return SliderConfig(range: 0...24, step: 0.1, precision: 1)
        case "momentumTransfer":
            return SliderConfig(range: 0...4, step: 0.05, precision: 2)
        case "settling":
            return SliderConfig(range: 0...1, step: 0.01, precision: 2)
        case "maxDiff":
            return SliderConfig(range: 0.001...0.2, step: 0.001, precision: 3)
        case "scale":
            return SliderConfig(range: -4...4, step: 0.01, precision: 2)
        case "riverValleyWidth":
            return SliderConfig(range: 0...12, step: 0.1, precision: 1)
        case "shorelineWidth":
            return SliderConfig(range: 0...12, step: 0.1, precision: 1)
        case "shorelineSharpness":
            return SliderConfig(range: 0...1, step: 0.01, precision: 2)
        case "bias":
            return SliderConfig(range: -1...1, step: 0.01, precision: 2)
        case "radius":
            return SliderConfig(range: 0...16, step: 1, precision: 0)
        case "headwaters":
            return SliderConfig(range: 1...64, step: 1, precision: 0)
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
                return SliderConfig(range: 1...300, step: 1, precision: 0)
            }
            return SliderConfig(range: 1...200, step: 1, precision: 0)
        case "dt":
            return SliderConfig(range: 0.001...0.1, step: 0.001, precision: 3)
        case "gravity":
            return SliderConfig(range: 0...6, step: 0.1, precision: 1)
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
