import Foundation
import SwiftUI
import TheiaCore

struct GraphParameter: Identifiable {
    let nodeId: String
    let name: String
    var value: Double

    var id: String { "\(nodeId).\(name)" }
}

struct GraphNodeInfo: Identifiable {
    let id: String
    let type: String
    var params: [GraphParameter]
}

final class TerrainModel: ObservableObject {
    @Published private(set) var nodes: [GraphNodeInfo] = []
    @Published private(set) var lastStats = ""
    @Published private(set) var document: GraphDocument
    @Published var selectedNodeId: String?
    @Published var selectedConnectionId: String?
    @Published private(set) var saveStatus = ""
    @Published private(set) var isDirty = false
    @Published var heightExaggeration = 0.5
    @Published var lightAzimuthDegrees = 35.0
    @Published var lightElevationDegrees = 58.0
    @Published var wireframeEnabled = false

    let engine: TerrainEngine
    let renderer: Renderer
    let size: UInt32
    let graphPath: String?
    let availableNodeTypes: [String]

    init(engine: TerrainEngine, renderer: Renderer, size: UInt32) {
        self.engine = engine
        self.renderer = renderer
        self.size = size
        graphPath = engine.graphPath
        availableNodeTypes = readCxxString { theia.node_type_list($0, $1) }
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if let path = engine.graphPath, let loaded = try? GraphDocument.load(path: path) {
            document = loaded
        } else {
            document = GraphDocument.defaultDocument()
        }
        reloadInspector()
        applyViewportSettings()
    }

    func record(_ result: theia.GraphEvalResult) {
        lastStats = "nodes \(result.evaluated), reused \(result.reused)"
    }

    func applyViewportSettings() {
        renderer.applyViewportSettings(heightExaggeration: heightExaggeration,
                                       lightAzimuthDegrees: lightAzimuthDegrees,
                                       lightElevationDegrees: lightElevationDegrees,
                                       wireframeEnabled: wireframeEnabled)
    }

    func resetCamera() {
        renderer.resetCamera()
    }

    func reloadInspector() {
        nodes = document.nodes.map { node in
            let params = node.params.keys.sorted().map {
                GraphParameter(nodeId: node.id, name: $0, value: node.params[$0] ?? 0)
            }
            return GraphNodeInfo(id: node.id, type: node.type, params: params)
        }
    }

    func apply(nodeId: String, param: String, value: Double) {
        document.setParam(nodeId: nodeId, key: param, value: value)
        markDirty()
        guard theia.graph_set_param(engine.handle, nodeId, param, value) else {
            lastStats = engine.lastError()
            return
        }
        _ = refreshTerrain()
        reloadInspector()
    }

    @discardableResult
    func refreshTerrain() -> Bool {
        guard let updated = engine.evaluate(size: size) else {
            lastStats = engine.lastError()
            return false
        }
        let w = Int(updated.result.width)
        let h = Int(updated.result.height)
        renderer.setHeights(updated.heights, width: w, height: h)
        lastStats = "nodes \(updated.result.evaluated), reused \(updated.result.reused)"
        return true
    }

    func hotReloadIfChanged() -> Bool {
        guard let path = graphPath else { return false }
        guard engine.reloadIfChanged() else { return false }
        if let loaded = try? GraphDocument.load(path: path) {
            document = loaded
            isDirty = false
            saveStatus = "reloaded"
        } else {
            saveStatus = "reloaded preview, document parse failed"
        }
        reloadInspector()
        _ = refreshTerrain()
        return true
    }

    func position(for nodeId: String) -> GraphNodePosition {
        document.ui?.positions[nodeId] ?? GraphNodePosition(x: 80, y: 80)
    }

    func selectNode(_ id: String?) {
        selectedNodeId = id
        selectedConnectionId = nil
    }

    func selectConnection(_ id: String?) {
        selectedConnectionId = id
        selectedNodeId = nil
    }

    func moveNode(id: String, by delta: CGSize) {
        let p = position(for: id)
        document.setPosition(nodeId: id,
                             x: max(0, p.x + delta.width),
                             y: max(0, p.y + delta.height))
        markDirty()
    }

    func moveNode(id: String, to position: GraphNodePosition) {
        document.setPosition(nodeId: id,
                             x: max(0, position.x),
                             y: max(0, position.y))
        markDirty()
    }

    func addNode(type: String) {
        let id = document.addNode(type: type)
        selectedNodeId = id
        selectedConnectionId = nil
        reloadGraphFromDocument()
        reloadInspector()
    }

    func deleteSelection() {
        if let edgeId = selectedConnectionId,
           let edge = document.connections.first(where: { $0.id == edgeId }) {
            document.disconnect(edge)
            selectedConnectionId = nil
            reloadGraphFromDocument()
            return
        }
        guard let nodeId = selectedNodeId else { return }
        document.deleteNode(id: nodeId)
        selectedNodeId = document.nodes.last?.id
        reloadGraphFromDocument()
        reloadInspector()
    }

    func connect(from: String, to: String, input: UInt32) {
        guard from != to, document.node(id: from) != nil,
              let target = document.node(id: to),
              input < document.inputCount(for: target.type) else { return }
        document.connect(from: from, to: to, input: input)
        selectedConnectionId = GraphDocumentConnection(from: from, to: to, input: input).id
        selectedNodeId = nil
        reloadGraphFromDocument()
    }

    func disconnect(_ edge: GraphDocumentConnection) {
        document.disconnect(edge)
        selectedConnectionId = nil
        reloadGraphFromDocument()
    }

    func setSink(_ id: String) {
        guard document.node(id: id) != nil else { return }
        document.sink = id
        reloadGraphFromDocument()
    }

    func resetLayout() {
        document.ui?.positions.removeAll()
        document.ensureLayout()
        markDirty()
    }

    func save() {
        guard let graphPath else {
            saveStatus = "no file path"
            return
        }
        do {
            let text = try document.encodedString()
            guard engine.loadJSONText(text) else {
                isDirty = true
                saveStatus = "save blocked: \(engine.lastError())"
                return
            }
            guard refreshTerrain() else {
                isDirty = true
                saveStatus = "save blocked: \(engine.lastError())"
                return
            }
            try text.write(toFile: graphPath, atomically: true, encoding: .utf8)
            isDirty = false
            saveStatus = "saved"
        } catch {
            saveStatus = "save failed: \(error.localizedDescription)"
        }
    }

    private func reloadGraphFromDocument() {
        do {
            let text = try document.encodedString()
            if engine.loadJSONText(text) {
                markDirty()
                if !refreshTerrain() {
                    saveStatus = "preview unchanged: \(engine.lastError())"
                }
            } else {
                isDirty = true
                saveStatus = "preview unchanged: \(engine.lastError())"
            }
        } catch {
            isDirty = true
            saveStatus = "preview unchanged: \(error.localizedDescription)"
        }
    }

    private func markDirty() {
        isDirty = true
        saveStatus = "unsaved"
    }
}
