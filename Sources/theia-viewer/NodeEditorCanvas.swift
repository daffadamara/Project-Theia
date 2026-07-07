import AppKit
import SwiftUI

private let nodeSize = CGSize(width: 150, height: 96)
private let inputGap: CGFloat = 18
private let minCanvasZoom = 0.35
private let maxCanvasZoom = 2.5

struct NodeEditorCanvas: View {
    @ObservedObject var model: TerrainModel
    let viewport: TerrainMTKView

    @State private var pan = CGSize(width: 24, height: 24)
    @State private var panDragStart: CGSize?
    @State private var zoom = 1.0
    @State private var nodeDragStarts: [String: GraphNodePosition] = [:]
    @State private var nodeDragId: String?
    @State private var marqueeStart: CGPoint?
    @State private var marqueeEnd: CGPoint?
    @State private var pendingSource: String?
    @State private var pendingPoint: CGPoint?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color(nsColor: .underPageBackgroundColor)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        model.clearSelectionToFlat()
                        viewport.setNeedsDisplay(viewport.bounds)
                    }

                CanvasGrid(pan: pan, zoom: zoom)

                ForEach(model.document.connections) { edge in
                    EdgeView(edge: edge,
                             start: screen(outputPort(edge.from)),
                             end: screen(inputPort(edge.to, input: edge.input)),
                             selected: model.selectedConnectionId == edge.id,
                             zoom: zoom)
                        .onTapGesture {
                            model.selectConnection(edge.id)
                        }
                        .contextMenu {
                            Button("Disconnect") {
                                model.disconnect(edge)
                            }
                        }
                }

                if let source = pendingSource, let point = pendingPoint {
                    EdgeShape(start: screen(outputPort(source)),
                              end: point,
                              minHandle: 50 * CGFloat(zoom))
                        .stroke(.blue, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                }

                if let rect = marqueeRect {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.16))
                        .overlay(Rectangle()
                            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }

                if model.document.nodes.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "rectangle.connected.to.line.below")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)
                        Text("No nodes")
                            .font(.headline)
                        Text("Right-click the canvas (or use Add) to create a terrain graph.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                ForEach(model.document.nodes) { node in
                    NodeCard(node: node,
                             position: screen(nodePosition(node.id)),
                             selected: model.selectedNodeIds.contains(node.id),
                             inputCount: model.document.inputCount(for: node.type),
                             connectedInputs: connectedInputs(for: node.id),
                             onSelect: { selectNode(node.id) },
                             onDelete: { model.selectNode(node.id); model.deleteSelection() },
                             onInputTap: { input in
                                 if let source = pendingSource {
                                     finishConnection(from: source, to: node.id, input: input)
                                 }
                             },
                             onInputDisconnect: { input in
                                 if let edge = model.document.connections.first(where: {
                                     $0.to == node.id && $0.input == input
                                 }) {
                                     model.disconnect(edge)
                                     viewport.setNeedsDisplay(viewport.bounds)
                                 }
                             },
                             onOutputDragChanged: { point in
                                 pendingSource = node.id
                                 pendingPoint = point
                             },
                             onOutputDragEnded: { point in
                                 finishConnectionDrop(from: node.id, point: point)
                             },
                             zoom: zoom)
                    .gesture(DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            if nodeDragId != node.id {
                                nodeDragId = node.id
                                if !model.selectedNodeIds.contains(node.id) {
                                    model.selectNode(node.id)
                                }
                                model.beginInteractiveMove()
                                nodeDragStarts = Dictionary(uniqueKeysWithValues:
                                    model.dragSelection(for: node.id).map {
                                        ($0, model.position(for: $0))
                                    })
                            }
                            let moved = nodeDragStarts.mapValues {
                                GraphNodePosition(
                                    x: $0.x + value.translation.width / zoom,
                                    y: $0.y + value.translation.height / zoom)
                            }
                            model.moveNodes(to: moved)
                        }
                        .onEnded { _ in
                            nodeDragId = nil
                            nodeDragStarts = [:]
                            model.endInteractiveMove()
                        })
                }
            }
            .coordinateSpace(name: "node-canvas")
            .clipped()
            .overlay(
                CanvasMouseEventView(
                    onChanged: { delta in
                        if panDragStart == nil { panDragStart = pan }
                        guard let start = panDragStart else { return }
                        pan = CGSize(width: start.width + delta.width,
                                     height: start.height - delta.height)
                    },
                    onEnded: {
                        panDragStart = nil
                    },
                    onZoom: { delta, point in
                        zoomCanvas(delta: delta, anchor: point)
                    },
                    onPanBy: { delta in
                        pan = CGSize(width: pan.width + delta.width,
                                     height: pan.height + delta.height)
                    },
                    nodeTypes: model.availableNodeTypes,
                    onAddNode: { type, point in
                        let doc = documentPoint(point)
                        model.addNode(type: type,
                                      at: GraphNodePosition(x: doc.x, y: doc.y))
                        viewport.setNeedsDisplay(viewport.bounds)
                    },
                    isOverNode: { point in
                        model.document.nodes.contains { node in
                            let origin = screen(nodePosition(node.id))
                            return CGRect(x: origin.x, y: origin.y,
                                          width: nodeSize.width * zoom,
                                          height: nodeSize.height * zoom)
                                .contains(point)
                        }
                    })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            )
            .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("node-canvas"))
                .onChanged { value in
                    if marqueeStart == nil {
                        marqueeStart = value.startLocation
                    }
                    marqueeEnd = value.location
                    updateMarqueeSelection()
                }
                .onEnded { _ in
                    updateMarqueeSelection()
                    marqueeStart = nil
                    marqueeEnd = nil
                })
            .onChange(of: geo.size) { _, _ in }
            .overlay(alignment: .topLeading) {
                CanvasToolbar(model: model, zoom: $zoom, viewport: viewport)
                    .padding(.top, 10)
                    .padding(.leading, 8)
            }
            .overlay(alignment: .bottomLeading) {
                CanvasGraphStatus(model: model)
                    .padding(.leading, 12)
                    .padding(.bottom, 12)
            }
        }
        .frame(minHeight: 220)
    }

    private func nodePosition(_ id: String) -> CGPoint {
        let p = model.position(for: id)
        return CGPoint(x: p.x, y: p.y)
    }

    private var marqueeRect: CGRect? {
        guard let start = marqueeStart, let end = marqueeEnd else { return nil }
        return CGRect(x: min(start.x, end.x),
                      y: min(start.y, end.y),
                      width: abs(end.x - start.x),
                      height: abs(end.y - start.y))
    }

    private func updateMarqueeSelection() {
        guard let rect = marqueeRect else { return }
        let selected = Set(model.document.nodes.compactMap { node -> String? in
            let p = screen(nodePosition(node.id))
            let nodeRect = CGRect(x: p.x, y: p.y,
                                  width: nodeSize.width * zoom,
                                  height: nodeSize.height * zoom)
            return rect.intersects(nodeRect) ? node.id : nil
        })
        model.selectNodesForMarquee(selected)
    }

    private func selectNode(_ id: String) {
        let flags = NSEvent.modifierFlags
        model.selectNode(id, extending: flags.contains(.shift) || flags.contains(.command))
    }

    private func screen(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x * zoom + pan.width, y: point.y * zoom + pan.height)
    }

    private func zoomCanvas(delta: CGFloat, anchor: CGPoint) {
        guard delta != 0 else { return }
        let previousZoom = zoom
        let multiplier = exp(delta * 0.01)
        let nextZoom = min(max(previousZoom * multiplier,
                               minCanvasZoom),
                           maxCanvasZoom)
        guard nextZoom != previousZoom else { return }

        let documentAnchor = documentPoint(anchor)
        zoom = nextZoom
        pan = CGSize(width: anchor.x - documentAnchor.x * nextZoom,
                     height: anchor.y - documentAnchor.y * nextZoom)
    }

    private func documentPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - pan.width) / zoom, y: (point.y - pan.height) / zoom)
    }

    private func outputPort(_ id: String) -> CGPoint {
        let p = nodePosition(id)
        return CGPoint(x: p.x + nodeSize.width, y: p.y + nodeSize.height * 0.5)
    }

    private func inputPort(_ id: String, input: UInt32) -> CGPoint {
        let p = nodePosition(id)
        return CGPoint(x: p.x, y: p.y + 34 + CGFloat(input) * inputGap)
    }

    private func connectedInputs(for nodeId: String) -> Set<UInt32> {
        Set(model.document.connections.compactMap { $0.to == nodeId ? $0.input : nil })
    }

    private func finishConnection(from: String, to: String, input: UInt32) {
        pendingSource = nil
        pendingPoint = nil
        model.connect(from: from, to: to, input: input)
        viewport.setNeedsDisplay(viewport.bounds)
    }

    private func finishConnectionDrop(from: String, point: CGPoint) {
        let docPoint = documentPoint(point)
        var best: (node: String, input: UInt32, distance: CGFloat)?
        for node in model.document.nodes {
            let count = model.document.inputCount(for: node.type)
            for input in 0..<count {
                let port = inputPort(node.id, input: input)
                let dx = port.x - docPoint.x
                let dy = port.y - docPoint.y
                let dist = sqrt(dx * dx + dy * dy)
                if dist < 22 && (best == nil || dist < best!.distance) {
                    best = (node.id, input, dist)
                }
            }
        }
        if let best {
            finishConnection(from: from, to: best.node, input: best.input)
        } else {
            pendingSource = nil
            pendingPoint = nil
        }
    }
}

struct CanvasGraphStatus: View {
    @ObservedObject var model: TerrainModel

    var body: some View {
        Label(primaryText, systemImage: primaryIcon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(Color.black.opacity(0.34),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .allowsHitTesting(false)
    }

    private var primaryIcon: String {
        model.document.nodes.isEmpty ? "rectangle.connected.to.line.below" : "point.3.connected.trianglepath.dotted"
    }

    private var primaryText: String {
        let count = model.document.nodes.count
        return "\(count) node\(count == 1 ? "" : "s")"
    }
}

struct CanvasToolbar: View {
    @ObservedObject var model: TerrainModel
    @Binding var zoom: Double
    let viewport: TerrainMTKView

    var body: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(model.availableNodeTypes, id: \.self) { type in
                    Button(type) {
                        model.addNode(type: type)
                        viewport.setNeedsDisplay(viewport.bounds)
                    }
                }
            } label: {
                toolbarLabel("Add", systemImage: "plus")
            }
            .buttonStyle(.plain)

            Button {
                model.deleteSelection()
                viewport.setNeedsDisplay(viewport.bounds)
            } label: {
                toolbarLabel("Delete", systemImage: "trash")
            }
            .buttonStyle(.plain)
            .disabled(model.selectedNodeId == nil && model.selectedConnectionId == nil)

            Button {
                model.resetLayout()
            } label: {
                toolbarLabel("Layout", systemImage: "rectangle.connected.to.line.below")
            }
            .buttonStyle(.plain)

            Button {
                model.undo()
                viewport.setNeedsDisplay(viewport.bounds)
            } label: {
                toolbarLabel("Undo", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(.plain)

            Button {
                model.redo()
                viewport.setNeedsDisplay(viewport.bounds)
            } label: {
                toolbarLabel("Redo", systemImage: "arrow.uturn.forward")
            }
            .buttonStyle(.plain)

            Slider(value: $zoom, in: minCanvasZoom...maxCanvasZoom, step: 0.1)
                .padding(.horizontal, 10)
                .frame(width: 124, height: 30)
                .background(toolbarFill,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    private var toolbarFill: Color {
        Color(red: 0.22, green: 0.22, blue: 0.24)
    }

    private func toolbarLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.9))
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(toolbarFill,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

struct NodeCard: View {
    let node: GraphDocumentNode
    let position: CGPoint
    let selected: Bool
    let inputCount: UInt32
    let connectedInputs: Set<UInt32>
    let onSelect: () -> Void
    let onDelete: () -> Void
    let onInputTap: (UInt32) -> Void
    let onInputDisconnect: (UInt32) -> Void
    let onOutputDragChanged: (CGPoint) -> Void
    let onOutputDragEnded: (CGPoint) -> Void
    let zoom: Double

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(borderColor,
                                lineWidth: selected ? 2 : 1))
                .shadow(color: .black.opacity(0.22), radius: 4, y: 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(node.id)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                }
                Text(node.type)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(10)

            if isMaskNode {
                Image(systemName: "circle.lefthalf.filled")
                    .font(.caption2)
                    .foregroundStyle(Color.cyan.opacity(0.85))
                    .position(x: nodeSize.width - 14, y: 14)
            }

            ForEach(0..<Int(inputCount), id: \.self) { input in
                PortView(color: .green)
                    .position(x: 0, y: 34 + CGFloat(input) * inputGap)
                    .onTapGesture { onInputTap(UInt32(input)) }
                    .contextMenu {
                        if connectedInputs.contains(UInt32(input)) {
                            Button("Disconnect") {
                                onInputDisconnect(UInt32(input))
                            }
                        }
                    }
            }

            PortView(color: .blue)
                .position(x: nodeSize.width, y: nodeSize.height * 0.5)
                .gesture(DragGesture(coordinateSpace: .named("node-canvas"))
                    .onChanged { onOutputDragChanged($0.location) }
                    .onEnded { onOutputDragEnded($0.location) })
        }
        .frame(width: nodeSize.width, height: nodeSize.height)
        .scaleEffect(zoom, anchor: .center)
        .position(x: position.x + nodeSize.width * CGFloat(zoom) * 0.5,
                  y: position.y + nodeSize.height * CGFloat(zoom) * 0.5)
        .onTapGesture(perform: onSelect)
        .contextMenu {
            Button("Delete", role: .destructive, action: onDelete)
        }
    }

    private var isMaskNode: Bool {
        node.type == "slopemask" || node.type == "river"
    }

    private var borderColor: Color {
        if selected { return .accentColor }
        if isMaskNode { return Color.cyan.opacity(0.55) }
        return Color.secondary.opacity(0.35)
    }
}

struct PortView: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 11, height: 11)
            .overlay(Circle().stroke(.white.opacity(0.75), lineWidth: 1))
    }
}

struct EdgeView: View {
    let edge: GraphDocumentConnection
    let start: CGPoint
    let end: CGPoint
    let selected: Bool
    let zoom: Double

    var body: some View {
        ZStack {
            EdgeShape(start: start, end: end, minHandle: 50 * CGFloat(zoom))
                .stroke(Color.primary.opacity(0.001),
                        style: StrokeStyle(lineWidth: max(6, 16 * CGFloat(zoom)),
                                           lineCap: .round))
            EdgeShape(start: start, end: end, minHandle: 50 * CGFloat(zoom))
                .stroke(selected ? Color.accentColor : Color.secondary,
                        style: StrokeStyle(lineWidth: max(1, (selected ? 3 : 2) * CGFloat(zoom)),
                                           lineCap: .round))
        }
    }
}

struct EdgeShape: Shape {
    var start: CGPoint
    var end: CGPoint
    var minHandle: CGFloat = 50

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let dx = max(minHandle, abs(end.x - start.x) * 0.45)
        p.move(to: start)
        p.addCurve(to: end,
                   control1: CGPoint(x: start.x + dx, y: start.y),
                   control2: CGPoint(x: end.x - dx, y: end.y))
        return p
    }
}

struct CanvasGrid: View {
    let pan: CGSize
    let zoom: Double

    var body: some View {
        Canvas { context, size in
            let step = max(6, 24 * CGFloat(zoom))
            var minor = Path()
            var major = Path()

            var x = pan.width.truncatingRemainder(dividingBy: step)
            if x > 0 { x -= step }
            while x <= size.width {
                let index = Int(round((x - pan.width) / step))
                if index.isMultiple(of: 5) {
                    major.move(to: CGPoint(x: x, y: 0))
                    major.addLine(to: CGPoint(x: x, y: size.height))
                } else {
                    minor.move(to: CGPoint(x: x, y: 0))
                    minor.addLine(to: CGPoint(x: x, y: size.height))
                }
                x += step
            }

            var y = pan.height.truncatingRemainder(dividingBy: step)
            if y > 0 { y -= step }
            while y <= size.height {
                let index = Int(round((y - pan.height) / step))
                if index.isMultiple(of: 5) {
                    major.move(to: CGPoint(x: 0, y: y))
                    major.addLine(to: CGPoint(x: size.width, y: y))
                } else {
                    minor.move(to: CGPoint(x: 0, y: y))
                    minor.addLine(to: CGPoint(x: size.width, y: y))
                }
                y += step
            }

            context.stroke(minor, with: .color(.secondary.opacity(0.10)), lineWidth: 1)
            context.stroke(major, with: .color(.secondary.opacity(0.18)), lineWidth: 1)
        }
    }
}

struct CanvasMouseEventView: NSViewRepresentable {
    let onChanged: (CGSize) -> Void
    let onEnded: () -> Void
    let onZoom: (CGFloat, CGPoint) -> Void
    let onPanBy: (CGSize) -> Void
    let nodeTypes: [String]
    let onAddNode: (String, CGPoint) -> Void
    let isOverNode: (CGPoint) -> Bool

    func makeNSView(context: Context) -> NSView {
        let view = CanvasMouseEventNSView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? CanvasMouseEventNSView else { return }
        apply(to: view)
    }

    private func apply(to view: CanvasMouseEventNSView) {
        view.onChanged = onChanged
        view.onEnded = onEnded
        view.onZoom = onZoom
        view.onPanBy = onPanBy
        view.nodeTypes = nodeTypes
        view.onAddNode = onAddNode
        view.isOverNode = isOverNode
    }
}

// Canvas navigation, following node-editor conventions (Godot GraphEdit /
// Blender / Figma):
//   two-finger scroll        pan
//   pinch or cmd+scroll      zoom about the cursor
//   right-drag / MMB-drag    pan
//   right-click empty space  add-node context menu at the cursor
final class CanvasMouseEventNSView: NSView {
    var onChanged: ((CGSize) -> Void)?
    var onEnded: (() -> Void)?
    var onZoom: ((CGFloat, CGPoint) -> Void)?
    var onPanBy: ((CGSize) -> Void)?
    var nodeTypes: [String] = []
    var onAddNode: ((String, CGPoint) -> Void)?
    var isOverNode: ((CGPoint) -> Bool)?
    private var start: NSPoint?
    private var dragDistance: CGFloat = 0
    private var contextPoint: CGPoint = .zero

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = window?.currentEvent else { return nil }
        switch event.type {
        case .rightMouseDown, .rightMouseDragged, .rightMouseUp:
            let local = convert(point, from: superview)
            let flipped = CGPoint(x: local.x, y: bounds.height - local.y)
            if event.type == .rightMouseDown, isOverNode?(flipped) == true {
                return nil
            }
            return self
        case .otherMouseDown, .otherMouseDragged, .otherMouseUp,
             .scrollWheel, .magnify:
            return self
        default:
            return nil
        }
    }

    override func rightMouseDown(with event: NSEvent) { beginDrag(event) }
    override func rightMouseDragged(with event: NSEvent) { dragged(event) }
    override func rightMouseUp(with event: NSEvent) {
        let wasClick = dragDistance < 4
        endDrag()
        if wasClick { showAddMenu(with: event) }
    }
    override func otherMouseDown(with event: NSEvent) { beginDrag(event) }
    override func otherMouseDragged(with event: NSEvent) { dragged(event) }
    override func otherMouseUp(with event: NSEvent) { endDrag() }

    private func beginDrag(_ event: NSEvent) {
        start = event.locationInWindow
        dragDistance = 0
    }

    private func dragged(_ event: NSEvent) {
        guard let start else { return }
        let p = event.locationInWindow
        dragDistance = max(dragDistance, abs(p.x - start.x) + abs(p.y - start.y))
        onChanged?(CGSize(width: p.x - start.x, height: p.y - start.y))
    }

    private func endDrag() {
        start = nil
        onEnded?()
    }

    override func scrollWheel(with event: NSEvent) {
        let point = localPoint(event)
        if event.modifierFlags.contains(.command) {
            onZoom?(event.scrollingDeltaY, point)
        } else {
            onPanBy?(CGSize(width: event.scrollingDeltaX,
                            height: event.scrollingDeltaY))
        }
    }

    override func magnify(with event: NSEvent) {
        onZoom?(event.magnification * 100, localPoint(event))
    }

    private func localPoint(_ event: NSEvent) -> CGPoint {
        let local = convert(event.locationInWindow, from: nil)
        return CGPoint(x: local.x, y: bounds.height - local.y)
    }

    private func showAddMenu(with event: NSEvent) {
        guard !nodeTypes.isEmpty else { return }
        contextPoint = localPoint(event)
        let menu = NSMenu()
        let header = NSMenuItem(title: "Add Node", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        for type in nodeTypes {
            let item = NSMenuItem(title: type,
                                  action: #selector(addNodeItem(_:)),
                                  keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func addNodeItem(_ sender: NSMenuItem) {
        onAddNode?(sender.title, contextPoint)
    }
}
