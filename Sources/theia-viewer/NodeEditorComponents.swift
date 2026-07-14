import AppKit
import SwiftUI

struct NodeCard: View {
    let node: GraphDocumentNode
    let position: CGPoint
    let selected: Bool
    let inputCount: UInt32
    let outputPorts: [GraphOutputPort]
    let connectedInputs: Set<UInt32>
    let missingInputs: Set<UInt32>
    let diagnosticSeverity: String?
    let onSelect: () -> Void
    let onDelete: () -> Void
    let onDuplicate: () -> Void
    let onSelectUpstream: () -> Void
    let onSelectDownstream: () -> Void
    let onInputTap: (UInt32) -> Void
    let onInputDisconnect: (UInt32) -> Void
    let onOutputDragChanged: (String, CGPoint) -> Void
    let onOutputDragEnded: (String, CGPoint) -> Void
    let zoom: Double

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(borderColor,
                                lineWidth: selected ? 2 : 1))
                .shadow(color: selected ? .accentColor.opacity(0.22) : .black.opacity(0.22),
                        radius: selected ? 7 : 4,
                        y: selected ? 0 : 2)

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

            if hasMaskOutput {
                Image(systemName: "circle.lefthalf.filled")
                    .font(.caption2)
                    .foregroundStyle(Color.cyan.opacity(0.85))
                    .position(x: nodeSize.width - 14, y: 14)
            }

            if node.type == "export" {
                badge(systemImage: "square.and.arrow.up",
                      color: .purple)
                    .position(x: nodeSize.width - 14, y: 14)
            }

            if let diagnosticSeverity {
                badge(systemImage: diagnosticSeverity == "error"
                      ? "exclamationmark.triangle.fill"
                      : "exclamationmark.circle.fill",
                      color: diagnosticSeverity == "error" ? .red : .orange)
                    .position(x: nodeSize.width - 14, y: hasMaskOutput || node.type == "export" ? 32 : 14)
                    .transition(.scale.combined(with: .opacity))
            }

            ForEach(0..<Int(inputCount), id: \.self) { input in
                PortView(color: .green,
                         warning: missingInputs.contains(UInt32(input)))
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

            ForEach(Array(outputPorts.enumerated()), id: \.element.name) { index, output in
                let startY = nodeSize.height * 0.5 -
                    CGFloat(max(0, outputPorts.count - 1)) * inputGap * 0.5
                Text(output.name)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .position(x: nodeSize.width - 31,
                              y: startY + CGFloat(index) * inputGap)
                PortView(color: portColor(output.declaredKind))
                    .position(x: nodeSize.width,
                              y: startY + CGFloat(index) * inputGap)
                    .gesture(DragGesture(coordinateSpace: .named("node-canvas"))
                        .onChanged { onOutputDragChanged(output.name, $0.location) }
                        .onEnded { onOutputDragEnded(output.name, $0.location) })
            }
        }
        .frame(width: nodeSize.width, height: nodeSize.height)
        .scaleEffect(zoom, anchor: .center)
        .position(x: position.x + nodeSize.width * CGFloat(zoom) * 0.5,
                  y: position.y + nodeSize.height * CGFloat(zoom) * 0.5)
        .onTapGesture(perform: onSelect)
        .animation(.easeOut(duration: 0.14), value: selected)
        .animation(.easeOut(duration: 0.14), value: diagnosticSeverity)
        .contextMenu {
            Button("Duplicate", action: onDuplicate)
            Divider()
            Button("Select Upstream", action: onSelectUpstream)
            Button("Select Downstream", action: onSelectDownstream)
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
    }

    private func badge(systemImage: String, color: Color) -> some View {
        Image(systemName: systemImage)
            .font(.caption2.weight(.bold))
            .foregroundStyle(color)
            .frame(width: 16, height: 16)
            .background(Color.black.opacity(0.42), in: Circle())
    }

    private var hasMaskOutput: Bool {
        outputPorts.contains { $0.declaredKind == .mask }
    }

    private var borderColor: Color {
        if selected { return .accentColor }
        if diagnosticSeverity == "error" { return Color.red.opacity(0.75) }
        if hasMaskOutput { return Color.cyan.opacity(0.55) }
        return Color.secondary.opacity(0.35)
    }

    private func portColor(_ kind: GraphFieldKind) -> Color {
        switch kind {
        case .terrain: return .blue
        case .mask: return .cyan
        case .data: return .orange
        }
    }
}

struct PortView: View {
    let color: Color
    var warning = false

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
        let groups = NodeTypeCatalog.grouped(nodeTypes)
        for (index, group) in groups.enumerated() {
            if index > 0 {
                menu.addItem(.separator())
            }
            let groupItem = NSMenuItem(title: group.title, action: nil, keyEquivalent: "")
            groupItem.image = NSImage(systemSymbolName: group.systemImage,
                                      accessibilityDescription: group.title)
            groupItem.isEnabled = false
            menu.addItem(groupItem)
            for type in group.types {
                let item = NSMenuItem(title: NodeTypeCatalog.title(for: type),
                                      action: #selector(addNodeItem(_:)),
                                      keyEquivalent: "")
                item.indentationLevel = 1
                item.representedObject = type
                item.target = self
                menu.addItem(item)
            }
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func addNodeItem(_ sender: NSMenuItem) {
        guard let type = sender.representedObject as? String else { return }
        onAddNode?(type, contextPoint)
    }
}
