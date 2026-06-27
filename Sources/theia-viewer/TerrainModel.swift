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
    @Published var heightExaggeration = 0.5
    @Published var lightAzimuthDegrees = 35.0
    @Published var lightElevationDegrees = 58.0
    @Published var wireframeEnabled = false

    let engine: TerrainEngine
    let renderer: Renderer
    let size: UInt32

    init(engine: TerrainEngine, renderer: Renderer, size: UInt32) {
        self.engine = engine
        self.renderer = renderer
        self.size = size
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
        var next: [GraphNodeInfo] = []
        let count = theia.graph_node_count(engine.handle)
        for i in 0..<count {
            let nodeId = readCxxString { theia.graph_node_id(engine.handle, i, $0, $1) }
            let type = readCxxString { theia.graph_node_type(engine.handle, i, $0, $1) }
            var params: [GraphParameter] = []
            let paramCount = theia.graph_param_count(engine.handle, nodeId)
            for p in 0..<paramCount {
                let name = readCxxString {
                    theia.graph_param_name(engine.handle, nodeId, p, $0, $1)
                }
                let value = theia.graph_param_value(engine.handle, nodeId, name, 0)
                params.append(GraphParameter(nodeId: nodeId, name: name, value: value))
            }
            next.append(GraphNodeInfo(id: nodeId, type: type, params: params))
        }
        nodes = next
    }

    func apply(nodeId: String, param: String, value: Double) {
        guard theia.graph_set_param(engine.handle, nodeId, param, value) else {
            lastStats = engine.lastError()
            return
        }
        refreshTerrain()
        reloadInspector()
    }

    func refreshTerrain() {
        guard let updated = engine.evaluate(size: size) else {
            lastStats = engine.lastError()
            return
        }
        let w = Int(updated.result.width)
        let h = Int(updated.result.height)
        renderer.setHeights(updated.heights, width: w, height: h)
        lastStats = "nodes \(updated.result.evaluated), reused \(updated.result.reused)"
    }

    func hotReloadIfChanged() -> Bool {
        guard engine.reloadIfChanged() else { return false }
        reloadInspector()
        refreshTerrain()
        return true
    }
}
