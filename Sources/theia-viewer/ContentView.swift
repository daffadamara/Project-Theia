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

                    AuthoringDock(model: model, viewport: viewport)
                        .frame(minWidth: 560, minHeight: 320, idealHeight: 380)
                        .layoutPriority(1)
                }
                .frame(minWidth: 560, minHeight: 680)

                InspectorPanel(model: model, viewport: viewport)
                    .frame(minWidth: 340, idealWidth: 400, maxWidth: 460)
            }

            StatusBadge(model: model)
                .padding(.trailing, 14)
                .padding(.bottom, 12)
        }
    }
}

private enum AuthoringDockTab: String, CaseIterable {
    case graph
    case output

    var title: String {
        switch self {
        case .graph: return "Graph"
        case .output: return "Output"
        }
    }

    var systemImage: String {
        switch self {
        case .graph: return "rectangle.connected.to.line.below"
        case .output: return "text.bubble"
        }
    }
}

struct AuthoringDock: View {
    @ObservedObject var model: TerrainModel
    let viewport: TerrainMTKView
    @State private var selectedTab: AuthoringDockTab = .graph
    private let uiSpring = Animation.spring(response: 0.24, dampingFraction: 0.86)

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch selectedTab {
                case .graph:
                    NodeEditorCanvas(model: model, viewport: viewport)
                        .transition(.opacity.combined(with: .scale(scale: 0.995, anchor: .bottom)))
                case .output:
                    GraphOutputPanel(model: model, viewport: viewport)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .animation(uiSpring, value: selectedTab)

            dockTabBar
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
        }
    }

    private var dockTabBar: some View {
        HStack(spacing: 6) {
            ForEach(AuthoringDockTab.allCases, id: \.self) { tab in
                Button {
                    withAnimation(uiSpring) {
                        selectedTab = tab
                    }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 12, weight: .semibold))
                        Text(tab.title)
                            .font(.system(size: 12, weight: .semibold))
                        if tab == .output {
                            outputBadge
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .foregroundStyle(selectedTab == tab ? .primary : .secondary)
                    .background(selectedTab == tab
                                ? Color.white.opacity(0.10)
                                : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .contentShape(Rectangle())
                    .scaleEffect(selectedTab == tab ? 1.0 : 0.98)
                    .animation(.easeOut(duration: 0.14), value: selectedTab)
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
        .padding(.horizontal, 8)
        .frame(height: 38)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private var outputBadge: some View {
        let errors = model.diagnostics.authoringErrorCount
        let warnings = model.diagnostics.authoringWarningCount
        if errors > 0 || warnings > 0 {
            Text("\(errors + warnings)")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(errors > 0 ? .red : .orange)
                .padding(.horizontal, 5)
                .frame(height: 16)
                .background((errors > 0 ? Color.red : Color.orange).opacity(0.14),
                            in: Capsule(style: .continuous))
                .transition(.scale.combined(with: .opacity))
                .animation(.spring(response: 0.22, dampingFraction: 0.78),
                           value: errors + warnings)
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
    @State private var expanded = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            Button {
                withAnimation(.easeOut(duration: 0.16)) {
                    expanded.toggle()
                }
            } label: {
                Group {
                    if expanded {
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(model.isDirty ? "Unsaved" : "Saved")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(model.isDirty ? .orange : .green)

                            Text(model.isDirty
                                 ? "Last saved \(savedTimestamp(relativeTo: timeline.date))"
                                 : savedTimestamp(relativeTo: timeline.date))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .bottomTrailing)))
                    } else {
                        Image(systemName: model.isDirty ? "clock.fill" : "checkmark.circle.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(model.isDirty ? .orange : .green)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                            .transition(.opacity.combined(with: .scale(scale: 0.86)))
                    }
                }
                .padding(.horizontal, expanded ? 10 : 4)
                .padding(.vertical, expanded ? 8 : 4)
                .background(Color.black.opacity(0.58),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .help(model.isDirty ? "Unsaved changes" : "Saved")
            .animation(.spring(response: 0.22, dampingFraction: 0.82),
                       value: expanded)
            .animation(.easeOut(duration: 0.18), value: model.isDirty)
        }
    }

    private func savedTimestamp(relativeTo now: Date) -> String {
        guard let savedAt = model.lastSavedAt else { return "Not saved yet" }
        let calendar = Calendar.current
        let seconds = max(0, Int(now.timeIntervalSince(savedAt)))
        if seconds < 60 { return "Just now" }
        let minutes = seconds / 60
        if calendar.isDateInToday(savedAt), minutes <= 15 {
            return "\(minutes) minute\(minutes == 1 ? "" : "s") ago"
        }
        let time = savedAt.formatted(.dateTime.hour().minute())
        if calendar.isDateInToday(savedAt) {
            return "Today at \(time)"
        }
        if calendar.isDateInYesterday(savedAt) {
            return "Yesterday at \(time)"
        }
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: now),
           savedAt >= weekAgo {
            let weekday = savedAt.formatted(.dateTime.weekday(.wide))
            return "\(weekday) at \(time)"
        }
        let day = savedAt.formatted(.dateTime.month(.abbreviated).day())
        return "\(day) at \(time)"
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
        VStack(alignment: .leading, spacing: 12) {
            exportHeader
            destinationSection
            resolutionSection
            outputsSection

            if !model.exportStatus.isEmpty {
                Label(model.exportStatus,
                      systemImage: model.exportStatus.hasPrefix("export failed") ? "xmark.circle.fill" : "info.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(model.exportStatus.hasPrefix("export failed") ? .red : .secondary)
                    .lineLimit(2)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            exportActionBar
        }
        .animation(.easeOut(duration: 0.14), value: model.exportStatus)
    }

    private var exportHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)

            Text("Export")
                .font(.title3.weight(.bold))

            Spacer()

            Menu {
                Button("Reset Export Settings", action: resetSettings)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: 30, height: 30)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .foregroundStyle(.secondary)
        }
        .padding(.top, 2)
    }

    private var destinationSection: some View {
        ExportInspectorCard {
            VStack(alignment: .leading, spacing: 16) {
                ExportSectionHeader("DESTINATION")

                HStack(alignment: .center, spacing: 12) {
                    ExportFieldLabel("Folder")

                    Text(model.exportSettings.outDir)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button {
                        chooseFolder()
                    } label: {
                        Text("Choose...")
                            .font(.callout.weight(.semibold))
                            .frame(width: 104, height: 34)
                            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .background(inspectorControlFill,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(inspectorControlStroke())
                }

                HStack(alignment: .center, spacing: 12) {
                    ExportFieldLabel("Preset / Name")

                    HStack(spacing: 8) {
                        TextField("terrain", text: Binding(
                            get: { model.exportSettings.basename },
                            set: { model.exportSettings.basename = $0 }))
                            .textFieldStyle(.plain)
                            .font(.callout.weight(.semibold))

                        if !model.exportSettings.basename.isEmpty {
                            Button {
                                model.exportSettings.basename = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .background(inspectorControlFill,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(inspectorControlStroke())
                }
            }
        }
    }

    private var resolutionSection: some View {
        ExportInspectorCard {
            VStack(alignment: .leading, spacing: 16) {
                ExportSectionHeader("RESOLUTION & SCALE")

                ExportMetricRow(icon: "square.grid.3x3.fill",
                                title: "Size (Resolution)",
                                value: Binding(
                                    get: { Double(model.exportSettings.size) },
                                    set: { model.exportSettings.size = UInt32(max(2, $0.rounded())) }),
                                range: 64...4096,
                                step: 64,
                                precision: 0)

                ExportMetricRow(icon: "mountain.2.fill",
                                title: "Vertical Scale",
                                value: Binding(
                                    get: { model.exportSettings.verticalScale },
                                    set: { model.exportSettings.verticalScale = max(0.001, $0) }),
                                range: 0.05...8,
                                step: 0.05,
                                precision: 2)

                ExportMetricRow(icon: "square.grid.3x3",
                                title: "Mesh Stride",
                                value: Binding(
                                    get: { Double(model.exportSettings.meshStride) },
                                    set: { model.exportSettings.meshStride = UInt32(max(1, $0.rounded())) }),
                                range: 1...16,
                                step: 1,
                                precision: 0)
            }
        }
    }

    private var outputsSection: some View {
        ExportInspectorCard {
            VStack(alignment: .leading, spacing: 14) {
                ExportSectionHeader("EXPORT OUTPUTS")

                ExportFormatRow(icon: "mountain.2.fill",
                                title: "Heightmap",
                                enabled: Binding(
                                    get: { model.exportSettings.exportHeightmap },
                                    set: { model.exportSettings.exportHeightmap = $0 })) {
                    Menu {
                        ForEach(ExportSettings.HeightmapFormat.allCases) { format in
                            Button(format.label) {
                                model.exportSettings.heightmapFormat = format
                            }
                        }
                    } label: {
                        ExportFormatMenuLabel(model.exportSettings.heightmapFormat.label)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                }

                ExportFormatRow(icon: "cube",
                                title: "Mesh",
                                enabled: Binding(
                                    get: { model.exportSettings.exportMesh },
                                    set: { model.exportSettings.exportMesh = $0 })) {
                    Menu {
                        ForEach(ExportSettings.MeshFormat.allCases) { format in
                            Button(format.isSupported ? format.label : "\(format.label) (later)") {
                                model.exportSettings.meshFormat = format
                            }
                            .disabled(!format.isSupported)
                        }
                    } label: {
                        ExportFormatMenuLabel(model.exportSettings.meshFormat.label)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                }
            }
        }
    }

    private var exportActionBar: some View {
        HStack(spacing: 10) {
            Button(action: resetSettings) {
                Label("Reset", systemImage: "arrow.counterclockwise")
                    .font(.callout.weight(.semibold))
                    .frame(minWidth: 84, minHeight: 34)
            }
            .buttonStyle(.plain)
            .background(inspectorControlFill,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(inspectorControlStroke())

            Spacer()

            Button {
                model.runExport()
            } label: {
                Label(model.isExporting ? "Exporting" : "Export",
                      systemImage: "square.and.arrow.up")
                    .font(.callout.weight(.semibold))
                    .frame(minWidth: 92, minHeight: 34)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(Color.accentColor,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .disabled(model.isExporting)
            .opacity(model.isExporting ? 0.65 : 1)
        }
        .padding(.top, 4)
    }

    private func resetSettings() {
        let outDir = model.exportSettings.outDir
        var defaults = ExportSettings()
        defaults.outDir = outDir
        model.exportSettings = defaults
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

private struct ExportInspectorCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(colors: [
                    Color.white.opacity(0.035),
                    Color.white.opacity(0.015)
                ], startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.10), lineWidth: 1))
    }
}

private struct ExportSectionHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.caption.weight(.heavy))
            .tracking(1.6)
            .foregroundStyle(.secondary)
    }
}

private struct ExportFieldLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.callout.weight(.semibold))
            .foregroundStyle(.primary.opacity(0.9))
            .frame(width: 112, alignment: .leading)
    }
}

private struct ExportMetricRow: View {
    let icon: String
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let precision: Int

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20)

            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.primary.opacity(0.9))
                .frame(width: 118, alignment: .leading)

            ExportPlainSlider(value: $value, range: range, step: step)
                .frame(maxWidth: .infinity)
                .frame(height: 24)

            InspectorValueBox(text: formattedValue)
        }
    }

    private var formattedValue: String {
        if precision == 0 {
            return String(Int(round(value)))
        }
        return String(format: "%.\(precision)f", value)
    }
}

private struct ExportPlainSlider: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var isContinuous: Bool = true

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(value: value,
                              minValue: range.lowerBound,
                              maxValue: range.upperBound,
                              target: context.coordinator,
                              action: #selector(Coordinator.changed(_:)))
        slider.isContinuous = isContinuous
        slider.numberOfTickMarks = 0
        slider.allowsTickMarkValuesOnly = false
        slider.controlSize = .small
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.parent = self
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.doubleValue = value
        slider.isContinuous = isContinuous
        slider.numberOfTickMarks = 0
        slider.allowsTickMarkValuesOnly = false
    }

    final class Coordinator: NSObject {
        var parent: ExportPlainSlider

        init(_ parent: ExportPlainSlider) {
            self.parent = parent
        }

        @MainActor @objc func changed(_ sender: NSSlider) {
            let raw = sender.doubleValue
            let stepped: Double
            if parent.step > 0 {
                stepped = (raw / parent.step).rounded() * parent.step
            } else {
                stepped = raw
            }
            parent.value = min(parent.range.upperBound,
                               max(parent.range.lowerBound, stepped))
        }
    }
}

private struct ExportFormatMenuLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            Spacer(minLength: 0)

            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .frame(width: 154, height: 34)
        .background(inspectorControlFill,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(inspectorControlStroke())
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct ExportFormatRow<Accessory: View>: View {
    let icon: String
    let title: String
    @Binding var enabled: Bool
    let accessory: Accessory

    init(icon: String,
         title: String,
         enabled: Binding<Bool>,
         @ViewBuilder accessory: () -> Accessory) {
        self.icon = icon
        self.title = title
        _enabled = enabled
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: $enabled)
                .labelsHidden()
                .toggleStyle(.checkbox)

            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20)

            Text(title)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .fixedSize(horizontal: true, vertical: false)

            Spacer(minLength: 8)

            accessory
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.45)
                .frame(width: 154)
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
        .background(Color.white.opacity(0.018),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1))
    }
}

private struct NoNodeParametersCard: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("No parameters")
                .font(.callout.weight(.semibold))
            Text("This node has no editable parameters.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .background(inspectorControlFill,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(inspectorControlStroke())
    }
}

private enum GraphOutputSeverity: String, CaseIterable {
    case all
    case error
    case warning
    case info

    var label: String {
        switch self {
        case .all: return "All"
        case .error: return "Errors"
        case .warning: return "Warnings"
        case .info: return "Info"
        }
    }

    var systemImage: String {
        switch self {
        case .all: return "line.3.horizontal.decrease.circle"
        case .error: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.circle.fill"
        case .info: return "info.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .all: return .secondary
        case .error: return .red
        case .warning: return .orange
        case .info: return .blue
        }
    }
}

private struct GraphOutputItem: Identifiable {
    let severity: GraphOutputSeverity
    let message: String
    let detail: String?
    let issue: GraphDiagnosticIssue?

    var id: String {
        if let issue { return issue.id }
        return [severity.rawValue, message, detail ?? ""].joined(separator: "|")
    }
}

struct GraphOutputPanel: View {
    @ObservedObject var model: TerrainModel
    let viewport: TerrainMTKView
    @State private var filter: GraphOutputSeverity = .all
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            outputHeader

            Divider()

            if filteredItems.isEmpty {
                emptyOutput
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filteredItems) { item in
                            Button {
                                if let issue = item.issue {
                                    model.selectDiagnosticIssue(issue)
                                    viewport.setNeedsDisplay(viewport.bounds)
                                }
                            } label: {
                                GraphOutputRow(item: item)
                            }
                            .buttonStyle(.plain)
                            .disabled(item.issue == nil)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var outputHeader: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(GraphOutputSeverity.allCases, id: \.self) { severity in
                    Button {
                        withAnimation(.easeOut(duration: 0.14)) {
                            filter = severity
                        }
                    } label: {
                        outputFilterSegment(severity)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField("Filter messages", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                if !searchText.isEmpty {
                    Button {
                        withAnimation(.easeOut(duration: 0.12)) {
                            searchText = ""
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(Color.black.opacity(0.18),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .animation(.easeOut(duration: 0.12), value: searchText.isEmpty)
    }

    private func outputFilterSegment(_ severity: GraphOutputSeverity) -> some View {
        HStack(spacing: 6) {
            Image(systemName: severity.systemImage)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(severity == .all ? .secondary : severity.color)
                .frame(width: 14)
            Text(severity.label)
                .font(.system(size: 12, weight: .semibold))
            if severity != .all {
                Text("\(count(for: severity))")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 10, alignment: .leading)
            }
        }
        .frame(minWidth: severity == .all ? 58 : 112, minHeight: 32)
        .padding(.horizontal, 4)
        .background(filter == severity
                    ? Color.white.opacity(0.12)
                    : Color.white.opacity(0.001),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .scaleEffect(filter == severity ? 1.0 : 0.98)
        .animation(.easeOut(duration: 0.14), value: filter)
    }

    private var emptyOutput: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.green)
            Text("No messages")
                .font(.headline)
            Text("Graph diagnostics will appear here.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var outputItems: [GraphOutputItem] {
        var items: [GraphOutputItem] = model.diagnostics.authoringIssues.map { issue in
            GraphOutputItem(severity: issue.isError ? .error : .warning,
                            message: issue.message,
                            detail: issue.node ?? issue.edge ?? issue.code,
                            issue: issue)
        }

        let authoringIds = Set(model.diagnostics.authoringIssues.map(\.id))
        let advisory = model.diagnostics.issues.filter { !authoringIds.contains($0.id) }
        items.append(contentsOf: advisory.map { issue in
            GraphOutputItem(severity: .info,
                            message: issue.message,
                            detail: issue.node ?? issue.edge ?? issue.code,
                            issue: issue)
        })

        if items.isEmpty {
            items.append(GraphOutputItem(
                severity: .info,
                message: "Graph is healthy",
                detail: "\(model.document.nodes.count) node\(model.document.nodes.count == 1 ? "" : "s"), \(model.document.connections.count) connection\(model.document.connections.count == 1 ? "" : "s")",
                issue: nil))
        }

        return items
    }

    private var filteredItems: [GraphOutputItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return outputItems.filter { item in
            let matchesFilter = filter == .all || item.severity == filter
            guard matchesFilter else { return false }
            guard !query.isEmpty else { return true }
            return item.message.lowercased().contains(query) ||
                (item.detail?.lowercased().contains(query) ?? false)
        }
    }

    private func count(for severity: GraphOutputSeverity) -> Int {
        outputItems.filter { $0.severity == severity }.count
    }
}

private struct GraphOutputRow: View {
    let item: GraphOutputItem

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(item.severity.color)
                .frame(width: 16, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.message)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = item.detail {
                    Text(detail)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.0001))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 1)
                .padding(.leading, 36)
        }
    }

    private var icon: String {
        switch item.severity {
        case .all:
            return "circle.fill"
        case .error:
            return "xmark.octagon.fill"
        case .warning:
            return "exclamationmark.circle.fill"
        case .info:
            return "info.circle.fill"
        }
    }
}

struct NodeParameterInspector: View {
    @ObservedObject var model: TerrainModel
    let viewport: TerrainMTKView
    @State private var advancedExpanded = false

    var visibleNodes: [GraphNodeInfo] {
        if let selected = model.selectedNodeId,
           let node = model.nodes.first(where: { $0.id == selected }) {
            return [node]
        }
        return []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Parameters")
                    .font(.headline.weight(.semibold))
                Spacer()
                Image(systemName: "chevron.up")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }

            if visibleNodes.isEmpty {
                Text(model.document.nodes.isEmpty ? "No nodes" : "No node selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }

            ForEach(visibleNodes) { node in
                VStack(alignment: .leading, spacing: 14) {
                    InspectorSectionHeader("SELECTED NODE")
                    NodeIdentityRow(node: node) {
                        model.resetAllParams(nodeId: node.id)
                        viewport.setNeedsDisplay(viewport.bounds)
                    }

                    if node.params.isEmpty {
                        NoNodeParametersCard()
                    } else {
                        Divider()
                            .padding(.vertical, 2)
                        InspectorSectionHeader("NODE SETTINGS")
                    }

                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(basicParams(for: node)) { param in
                            ParameterSlider(param: param) { value in
                                model.apply(nodeId: param.nodeId,
                                            param: param.name,
                                            value: value)
                                viewport.setNeedsDisplay(viewport.bounds)
                            } onReset: {
                                model.resetParam(nodeId: param.nodeId,
                                                 param: param.name)
                                viewport.setNeedsDisplay(viewport.bounds)
                            }
                        }
                    }

                    let advanced = advancedParams(for: node)
                    if !advanced.isEmpty {
                        DisclosureGroup(isExpanded: $advancedExpanded) {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(advanced) { param in
                                    ParameterSlider(param: param) { value in
                                        model.apply(nodeId: param.nodeId,
                                                    param: param.name,
                                                    value: value)
                                        viewport.setNeedsDisplay(viewport.bounds)
                                    } onReset: {
                                        model.resetParam(nodeId: param.nodeId,
                                                         param: param.name)
                                        viewport.setNeedsDisplay(viewport.bounds)
                                    }
                                }
                            }
                            .padding(.top, 8)
                        } label: {
                            HStack {
                                InspectorSectionHeader("ADVANCED")
                                Spacer()
                            }
                        }
                        .font(.caption.weight(.semibold))
                    }
                }
            }
        }
    }

    private func basicParams(for node: GraphNodeInfo) -> [GraphParameter] {
        node.params.filter { ParameterPresentation.for($0).group == .basic }
    }

    private func advancedParams(for node: GraphNodeInfo) -> [GraphParameter] {
        node.params.filter { ParameterPresentation.for($0).group == .advanced }
    }
}

private struct InspectorSectionHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.caption.weight(.bold))
            .tracking(0.7)
            .foregroundStyle(.secondary)
    }
}

private struct NodeIdentityRow: View {
    let node: GraphNodeInfo
    let onResetAll: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(node.id)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text(NodeTypeName.display(node.type))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(node.type)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Color.black.opacity(0.16),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1))
            Button(action: onResetAll) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .background(Color.black.opacity(0.16),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1))
            .help("Reset all parameters")
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
    let onReset: () -> Void

    @State private var value: Double
    private let config: SliderConfig
    private let presentation: ParameterPresentation

    init(param: GraphParameter,
         onChange: @escaping (Double) -> Void,
         onReset: @escaping () -> Void) {
        self.param = param
        self.onChange = onChange
        self.onReset = onReset
        _value = State(initialValue: param.value)
        config = SliderConfig.forParam(param)
        presentation = ParameterPresentation.for(param)
    }

    var body: some View {
        VStack(spacing: 0) {
            if param.nodeType == "blend", param.name == "mode" {
                row {
                    Menu {
                        ForEach(0..<blendModeNames.count, id: \.self) { mode in
                            Button(blendModeNames[mode]) {
                                value = Double(mode)
                                onChange(value)
                            }
                        }
                    } label: {
                        ParameterMenuLabel(title: blendModeName(Int(round(value))))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                }
            } else {
                row {
                    ExportPlainSlider(value: Binding(
                        get: { value },
                        set: { newValue in
                            value = newValue
                            onChange(newValue)
                        }),
                                      range: config.range,
                                      step: config.step,
                                      isContinuous: true)
                        .frame(minWidth: 96)
                }
            }

            Divider()
                .opacity(0.45)
                .padding(.top, 12)
        }
        .padding(.vertical, 8)
        .onChange(of: param.value) { _, newValue in
            value = newValue
        }
    }

    private func row<Control: View>(@ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .center, spacing: 10) {
            ParameterIconBox(systemName: presentation.icon)

            VStack(alignment: .leading, spacing: 3) {
                Text(presentation.label)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)

                if let detail = presentation.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: 132, alignment: .leading)

            control()
                .frame(maxWidth: .infinity)

            Button(action: onReset) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .background(inspectorControlFill,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(inspectorControlStroke())
            .help("Reset \(presentation.label)")

            InspectorValueBox(text: presentation.format(value, config: config))
        }
        .frame(minHeight: 66)
    }

    private var blendModeNames: [String] {
        ["mix", "add", "multiply", "max", "min", "screen"]
    }

    private func blendModeName(_ mode: Int) -> String {
        guard blendModeNames.indices.contains(mode) else { return "mix" }
        return blendModeNames[mode]
    }
}

private struct ParameterMenuLabel: View {
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Spacer(minLength: 0)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
        .frame(height: 34)
        .background(inspectorControlFill,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(inspectorControlStroke())
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct ParameterIconBox: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 34, height: 34)
            .background(inspectorControlFill,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(inspectorControlStroke())
    }
}

private enum ParameterGroup {
    case basic
    case advanced
}

private struct ParameterPresentation {
    let label: String
    let detail: String?
    let unit: String?
    let icon: String
    let group: ParameterGroup

    func format(_ value: Double, config: SliderConfig) -> String {
        let base: String
        if unit == nil && config.precision == 0 {
            base = String(Int(round(value)))
        } else {
            base = config.format(value)
        }
        guard let unit else { return base }
        return "\(base)\(unit)"
    }

    static func `for`(_ param: GraphParameter) -> ParameterPresentation {
        ParameterPresentation(label: label(for: param.name),
                              detail: detail(for: param),
                              unit: unit(for: param),
                              icon: icon(for: param),
                              group: group(for: param))
    }

    private static func label(for name: String) -> String {
        switch name {
        case "dt": return "Delta Time"
        case "t": return "Mix"
        case "inLow": return "Input Low"
        case "inHigh": return "Input High"
        case "outLow": return "Output Low"
        case "outHigh": return "Output High"
        case "riverValleyWidth": return "Valley Width"
        case "shorelineWidth": return "Shoreline Width"
        case "shorelineSharpness": return "Shore Sharpness"
        case "heightScale": return "Height Scale"
        case "ridgeSharpness": return "Ridge Sharpness"
        case "maxAge": return "Max Age"
        case "maxDiff": return "Max Diff"
        case "momentumTransfer": return "Momentum"
        case "pipeArea": return "Pipe Area"
        case "pipeLength": return "Pipe Length"
        case "cellSize": return "Cell Size"
        case "renderSurface": return "Render Surface"
        default:
            return ParameterName.display(name)
        }
    }

    private static func detail(for param: GraphParameter) -> String? {
        switch param.name {
        case "frequency": return "Controls the overall scale."
        case "gain": return "Controls the amplitude."
        case "heightScale": return "Scales the output height."
        case "lacunarity": return "Gap between successive frequencies."
        case "octaves": return "Number of noise layers."
        case "particles": return "Simulation budget."
        case "iterations": return "Simulation pass count."
        case "maxAge": return "Particle lifetime."
        case "seed": return "Deterministic variation."
        case "mode" where param.nodeType == "blend": return "Blend formula."
        case "t": return "Mixes the first and second input."
        case "opacity": return "Controls blend contribution."
        case "scale": return "Multiplies incoming values."
        case "bias": return "Offsets incoming values."
        case "amount": return "Interpolates toward the effect."
        case "min": return "Lower clamp boundary."
        case "max": return "Upper clamp boundary."
        case "inLow": return "Input range start."
        case "inHigh": return "Input range end."
        case "outLow": return "Output range start."
        case "outHigh": return "Output range end."
        case "gamma": return "Shapes the remap curve."
        case "clamp": return "Limits values to the output range."
        case "radius": return "Filter sample radius."
        case "strength": return "Controls effect intensity."
        case "sharpness": return "Controls transition hardness."
        case "ridgeSharpness": return "Controls ridge contrast."
        case "steps": return "Number of terrace levels."
        case "low": return param.nodeType == "slopemask" ? "Minimum slope angle." : "Lower threshold."
        case "high": return param.nodeType == "slopemask" ? "Maximum slope angle." : "Upper threshold."
        case "depth": return "Controls carving depth."
        case "downcutting": return "Cuts channels into terrain."
        case "riverValleyWidth": return "Widens the carved valley."
        case "shorelineWidth": return "Softens riverbank width."
        case "shorelineSharpness": return "Controls bank edge hardness."
        case "headwaters": return "Number of river sources."
        case "water": return "Controls mask fill strength."
        case "deposition": return "Deposits carried sediment."
        case "entrainment": return "Picks up terrain sediment."
        case "evaporation": return "Reduces water over time."
        case "gravity": return "Controls downhill force."
        case "momentumTransfer": return "Carries flow direction forward."
        case "settling": return "Smooths unstable slopes."
        case "maxDiff": return "Limits local height changes."
        case "dt": return "Simulation timestep."
        case "minTilt": return "Minimum flow slope."
        case "rain": return "Adds water each iteration."
        case "sedimentCapacity": return "Maximum carried sediment."
        case "suspension": return "Keeps sediment in flow."
        case "pipeArea": return "Virtual pipe cross-section."
        case "pipeLength": return "Virtual pipe length."
        case "cellSize": return "Terrain sampling size."
        case "talusAngle": return "Slope stability threshold."
        case "renderSurface": return "Switches preview surface mode."
        default: return nil
        }
    }

    private static func icon(for param: GraphParameter) -> String {
        switch param.name {
        case "frequency": return "waveform.path.ecg"
        case "gain": return "chart.line.uptrend.xyaxis"
        case "heightScale": return "mountain.2.fill"
        case "lacunarity": return "circle.dotted"
        case "octaves": return "square.3.layers.3d.down.right"
        case "seed": return "number"
        case "strength": return "dial.medium"
        case "radius": return "circle"
        case "width", "riverValleyWidth", "shorelineWidth": return "arrow.left.and.right"
        case "depth", "downcutting": return "arrow.down"
        case "water": return "drop.fill"
        case "particles", "iterations", "maxAge": return "timer"
        case "evaporation": return "cloud"
        case "deposition", "settling": return "tray.and.arrow.down"
        case "entrainment": return "wind"
        case "gravity": return "arrow.down.to.line"
        case "momentumTransfer": return "forward.frame"
        case "mode": return "square.stack.3d.up"
        default: return "slider.horizontal.3"
        }
    }

    private static func unit(for param: GraphParameter) -> String? {
        switch param.name {
        case "low" where param.nodeType == "slopemask",
             "high" where param.nodeType == "slopemask":
            return "°"
        default:
            return nil
        }
    }

    private static func group(for param: GraphParameter) -> ParameterGroup {
        let advancedNames: Set<String> = [
            "particles", "maxAge", "iterations", "dt", "pipeArea",
            "pipeLength", "rain", "sedimentCapacity", "suspension",
            "cellSize", "evaporation", "deposition", "entrainment",
            "gravity", "momentumTransfer", "settling", "maxDiff"
        ]
        if advancedNames.contains(param.name) {
            return .advanced
        }
        if param.nodeType == "hydraulic" || param.nodeType == "dropleterosion" {
            switch param.name {
            case "heightScale", "depth", "downcutting", "riverValleyWidth":
                return .basic
            default:
                return advancedNames.contains(param.name) ? .advanced : .basic
            }
        }
        return .basic
    }
}

private let inspectorControlFill = Color.black.opacity(0.18)

private func inspectorControlStroke() -> some View {
    RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(Color.white.opacity(0.10), lineWidth: 1)
}

private struct InspectorValueBox: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout.monospacedDigit().weight(.semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(width: 76, height: 34)
            .background(inspectorControlFill,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(inspectorControlStroke())
    }
}

private enum NodeTypeName {
    static func display(_ type: String) -> String {
        switch type {
        case "scalebias": return "Scale Bias"
        case "dropleterosion": return "Droplet Erosion"
        case "rivercarve": return "River Carve"
        case "slopemask": return "Slope Mask"
        default:
            return splitCamel(type.prefix(1).uppercased() + type.dropFirst())
        }
    }
}

private enum ParameterName {
    static func display(_ name: String) -> String {
        switch name {
        case "dt": return "Delta Time"
        case "t": return "Mix"
        default:
            return splitCamel(name.prefix(1).uppercased() + name.dropFirst())
        }
    }
}

private func splitCamel<S: StringProtocol>(_ value: S) -> String {
    var output = ""
    for scalar in String(value).unicodeScalars {
        let char = Character(scalar)
        if CharacterSet.uppercaseLetters.contains(scalar),
           !output.isEmpty,
           !output.hasSuffix(" ") {
            output.append(" ")
        }
        output.append(char)
    }
    return output
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
