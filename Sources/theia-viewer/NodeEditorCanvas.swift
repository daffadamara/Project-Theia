import SwiftUI

private let nodeSize = CGSize(width: 150, height: 96)
private let inputGap: CGFloat = 18

struct NodeEditorCanvas: View {
    @ObservedObject var model: TerrainModel
    let viewport: TerrainMTKView

    @State private var pan = CGSize(width: 24, height: 24)
    @State private var panDragStart: CGSize?
    @State private var zoom = 1.0
    @State private var nodeDragStart: GraphNodePosition?
    @State private var nodeDragId: String?
    @State private var pendingSource: String?
    @State private var pendingPoint: CGPoint?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color(nsColor: .underPageBackgroundColor)

                CanvasGrid()
                    .scaleEffect(zoom, anchor: .topLeading)
                    .offset(pan)

                ForEach(model.document.connections) { edge in
                    EdgeView(edge: edge,
                             start: screen(outputPort(edge.from)),
                             end: screen(inputPort(edge.to, input: edge.input)),
                             selected: model.selectedConnectionId == edge.id)
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
                    EdgeShape(start: screen(outputPort(source)), end: point)
                        .stroke(.blue, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                }

                if model.document.nodes.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "rectangle.connected.to.line.below")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)
                        Text("No nodes")
                            .font(.headline)
                        Text("Use Add to create a terrain graph.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                ForEach(model.document.nodes) { node in
                    NodeCard(node: node,
                             position: screen(nodePosition(node.id)),
                             selected: model.selectedNodeId == node.id,
                             isSink: model.document.sink == node.id,
                             inputCount: model.document.inputCount(for: node.type),
                             connectedInputs: connectedInputs(for: node.id),
                             onSelect: { model.selectNode(node.id) },
                             onSetSink: { model.setSink(node.id) },
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
                             })
                    .gesture(DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            if nodeDragId != node.id {
                                nodeDragId = node.id
                                nodeDragStart = model.position(for: node.id)
                            }
                            guard let start = nodeDragStart else { return }
                            model.selectNode(node.id)
                            model.moveNode(id: node.id,
                                           to: GraphNodePosition(
                                            x: start.x + value.translation.width / zoom,
                                            y: start.y + value.translation.height / zoom))
                        }
                        .onEnded { _ in
                            nodeDragId = nil
                            nodeDragStart = nil
                        })
                }
            }
            .coordinateSpace(name: "node-canvas")
            .clipped()
            .gesture(DragGesture(minimumDistance: 8)
                .onChanged { value in
                    if panDragStart == nil {
                        panDragStart = pan
                    }
                    guard let start = panDragStart else { return }
                    pan = CGSize(width: start.width + value.translation.width,
                                 height: start.height + value.translation.height)
                }
                .onEnded { _ in
                    panDragStart = nil
                })
            .onChange(of: geo.size) { _, _ in }
            .overlay(alignment: .topLeading) {
                CanvasToolbar(model: model, zoom: $zoom, viewport: viewport)
                    .padding(8)
            }
        }
        .frame(minHeight: 220)
    }

    private func nodePosition(_ id: String) -> CGPoint {
        let p = model.position(for: id)
        return CGPoint(x: p.x, y: p.y)
    }

    private func screen(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x * zoom + pan.width, y: point.y * zoom + pan.height)
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
                Label("Add", systemImage: "plus")
            }

            Button {
                model.deleteSelection()
                viewport.setNeedsDisplay(viewport.bounds)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(model.selectedNodeId == nil && model.selectedConnectionId == nil)

            Button {
                model.resetLayout()
            } label: {
                Label("Layout", systemImage: "rectangle.connected.to.line.below")
            }

            Slider(value: $zoom, in: 0.5...1.6, step: 0.1)
                .frame(width: 100)
        }
        .padding(7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
    }
}

struct NodeCard: View {
    let node: GraphDocumentNode
    let position: CGPoint
    let selected: Bool
    let isSink: Bool
    let inputCount: UInt32
    let connectedInputs: Set<UInt32>
    let onSelect: () -> Void
    let onSetSink: () -> Void
    let onDelete: () -> Void
    let onInputTap: (UInt32) -> Void
    let onInputDisconnect: (UInt32) -> Void
    let onOutputDragChanged: (CGPoint) -> Void
    let onOutputDragEnded: (CGPoint) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(selected ? Color.accentColor : Color.secondary.opacity(0.35),
                                lineWidth: selected ? 2 : 1))
                .shadow(color: .black.opacity(0.22), radius: 4, y: 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(node.id)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                    if isSink {
                        Text("sink")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                    }
                }
                Text(node.type)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(10)

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
        .position(x: position.x + nodeSize.width * 0.5,
                  y: position.y + nodeSize.height * 0.5)
        .onTapGesture(perform: onSelect)
        .contextMenu {
            Button("Set as Sink", action: onSetSink)
            Button("Delete", role: .destructive, action: onDelete)
        }
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

    var body: some View {
        ZStack {
            EdgeShape(start: start, end: end)
                .stroke(Color.primary.opacity(0.001),
                        style: StrokeStyle(lineWidth: 16, lineCap: .round))
            EdgeShape(start: start, end: end)
                .stroke(selected ? Color.accentColor : Color.secondary,
                        style: StrokeStyle(lineWidth: selected ? 3 : 2,
                                           lineCap: .round))
        }
    }
}

struct EdgeShape: Shape {
    var start: CGPoint
    var end: CGPoint

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let dx = max(50, abs(end.x - start.x) * 0.45)
        p.move(to: start)
        p.addCurve(to: end,
                   control1: CGPoint(x: start.x + dx, y: start.y),
                   control2: CGPoint(x: end.x - dx, y: end.y))
        return p
    }
}

struct CanvasGrid: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            let step: CGFloat = 24
            var x: CGFloat = 0
            while x < size.width * 2 {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height * 2))
                x += step
            }
            var y: CGFloat = 0
            while y < size.height * 2 {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width * 2, y: y))
                y += step
            }
            context.stroke(path, with: .color(.secondary.opacity(0.12)), lineWidth: 1)
        }
    }
}
