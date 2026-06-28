import Foundation
import SwiftUI
import TheiaCore

struct GraphParameter: Identifiable {
    let nodeId: String
    let nodeType: String
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
    @Published private(set) var selectedNodeIds: Set<String> = []
    @Published var selectedConnectionId: String?
    @Published private(set) var saveStatus = ""
    @Published private(set) var isDirty = false
    @Published var lightAzimuthDegrees = 35.0
    @Published var lightElevationDegrees = 58.0
    @Published var wireframeEnabled = false
    @Published var displayMode: ViewportDisplayMode = .auto
    @Published var materialPreset: MaterialPreset = .natural
    @Published var maskOpacity = 0.65

    let engine: TerrainEngine
    let renderer: Renderer
    let size: UInt32
    @Published private(set) var graphPath: String?
    let availableNodeTypes: [String]
    private var documentCanSave = true
    private var undoStack: [GraphDocument] = []
    private var redoStack: [GraphDocument] = []
    private var isRestoringHistory = false
    private var isInteractiveMove = false
    private let maskUtilityTypes: Set<String> = ["invert", "clamp", "remap", "blur"]

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
        loadPreviewSettingsFromDocument()
        reloadInspector()
        syncPreviewWithDocument(markDirty: false)
        applyViewportSettings()
    }

    func record(_ result: theia.GraphEvalResult) {
        lastStats = "nodes \(result.evaluated), reused \(result.reused)"
    }

    func applyViewportSettings(displayMode override: ViewportDisplayMode? = nil) {
        renderer.applyViewportSettings(lightAzimuthDegrees: lightAzimuthDegrees,
                                       lightElevationDegrees: lightElevationDegrees,
                                       wireframeEnabled: wireframeEnabled,
                                       displayMode: override ?? effectiveDisplayMode(for: document.sink),
                                       materialPreset: materialPreset,
                                       maskOpacity: maskOpacity)
    }

    func resetCamera() {
        renderer.resetCamera()
    }

    func setDisplayMode(_ mode: ViewportDisplayMode) {
        displayMode = mode
        persistPreviewSettings()
        _ = refreshTerrain()
    }

    func setMaterialPreset(_ preset: MaterialPreset) {
        materialPreset = preset
        persistPreviewSettings()
        applyViewportSettings()
    }

    func setMaskOpacity(_ opacity: Double) {
        maskOpacity = min(max(opacity, 0), 1)
        persistPreviewSettings()
        applyViewportSettings()
    }

    func activeDisplayModeLabel() -> String {
        effectiveDisplayMode(for: document.sink).label
    }

    func reloadInspector() {
        nodes = document.nodes.map { node in
            let params = node.params.keys.sorted().map {
                GraphParameter(nodeId: node.id, nodeType: node.type,
                               name: $0, value: node.params[$0] ?? 0)
            }
            return GraphNodeInfo(id: node.id, type: node.type, params: params)
        }
    }

    func apply(nodeId: String, param: String, value: Double) {
        pushUndo()
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
        let dataSink = document.sink
        guard !dataSink.isEmpty else {
            setFlatPreview(status: document.nodes.isEmpty ? "empty graph" : "no output")
            return true
        }

        let mode = effectiveDisplayMode(for: dataSink)
        let geometrySink = geometrySink(for: dataSink, mode: mode) ?? dataSink
        guard let geometry = engine.evaluate(size: size, sink: geometrySink) else {
            lastStats = engine.lastError()
            return false
        }
        let data: (heights: [Float], result: theia.GraphEvalResult)
        if geometrySink == dataSink {
            data = geometry
        } else {
            guard let evaluatedData = engine.evaluate(size: size, sink: dataSink) else {
                lastStats = engine.lastError()
                return false
            }
            data = evaluatedData
        }

        let w = Int(geometry.result.width)
        let h = Int(geometry.result.height)
        renderer.setPreview(heights: geometry.heights, data: data.heights, width: w, height: h)
        applyViewportSettings(displayMode: mode)

        let evaluated = geometry.result.evaluated +
            (geometrySink == dataSink ? 0 : data.result.evaluated)
        let reused = geometry.result.reused +
            (geometrySink == dataSink ? 0 : data.result.reused)
        lastStats = "nodes \(evaluated), reused \(reused)"
        return true
    }

    func setFlatPreview(status: String = "flat preview") {
        let dim = max(2, Int(size == 0 ? document.resolution.width : size))
        let flat = [Float](repeating: 0, count: dim * dim)
        renderer.setPreview(heights: flat, data: flat, width: dim, height: dim)
        applyViewportSettings(displayMode: .terrain)
        lastStats = status
    }

    func hotReloadIfChanged() -> Bool {
        guard let path = graphPath else { return false }
        guard engine.reloadIfChanged() else { return false }
        if let loaded = try? GraphDocument.load(path: path) {
            document = loaded
            loadPreviewSettingsFromDocument()
            isDirty = false
            saveStatus = "reloaded"
        } else {
            saveStatus = "reloaded preview, document parse failed"
        }
        reloadInspector()
        syncPreviewWithDocument(markDirty: false)
        return true
    }

    func position(for nodeId: String) -> GraphNodePosition {
        document.ui?.positions[nodeId] ?? GraphNodePosition(x: 80, y: 80)
    }

    func selectNode(_ id: String?, extending: Bool = false) {
        selectedConnectionId = nil
        guard let id else {
            selectedNodeId = nil
            selectedNodeIds = []
            return
        }
        selectedNodeId = id
        if extending {
            selectedNodeIds.insert(id)
        } else {
            selectedNodeIds = [id]
        }
        guard document.sink != id else { return }
        pushUndo()
        document.sink = id
        syncPreviewWithDocument(markDirty: true)
    }

    func selectNodes(_ ids: Set<String>) {
        selectedConnectionId = nil
        selectedNodeIds = ids
        selectedNodeId = ids.sorted().last
        if let selectedNodeId, document.sink != selectedNodeId {
            pushUndo()
            document.sink = selectedNodeId
            syncPreviewWithDocument(markDirty: true)
        }
    }

    func previewSelectedNode() {
        guard let selectedNodeId, document.sink != selectedNodeId else { return }
        pushUndo()
        document.sink = selectedNodeId
        syncPreviewWithDocument(markDirty: true)
    }

    func selectNodesForMarquee(_ ids: Set<String>) {
        guard selectedConnectionId != nil || selectedNodeIds != ids else { return }
        if ids.isEmpty {
            clearSelectionToFlat(recordUndo: false)
            return
        }
        selectedConnectionId = nil
        selectedNodeIds = ids
        selectedNodeId = ids.sorted().last
    }

    func clearSelectionToFlat(recordUndo: Bool = true) {
        selectedConnectionId = nil
        selectedNodeId = nil
        selectedNodeIds = []
        guard !document.sink.isEmpty else {
            setFlatPreview(status: document.nodes.isEmpty ? "empty graph" : "no selection")
            return
        }
        if recordUndo { pushUndo() }
        document.sink = ""
        markDirty()
        documentCanSave = true
        setFlatPreview(status: document.nodes.isEmpty ? "empty graph" : "no selection")
    }

    func selectConnection(_ id: String?) {
        selectedConnectionId = id
        selectedNodeId = nil
        selectedNodeIds = []
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

    func moveNodes(to positions: [String: GraphNodePosition]) {
        if !isRestoringHistory && !isInteractiveMove { pushUndo() }
        for (id, position) in positions {
            document.setPosition(nodeId: id,
                                 x: max(0, position.x),
                                 y: max(0, position.y))
        }
        markDirty()
    }

    func dragSelection(for id: String) -> Set<String> {
        selectedNodeIds.contains(id) ? selectedNodeIds : [id]
    }

    func beginInteractiveMove() {
        guard !isInteractiveMove else { return }
        pushUndo()
        isInteractiveMove = true
    }

    func endInteractiveMove() {
        isInteractiveMove = false
    }

    func addNode(type: String) {
        pushUndo()
        let previous = selectedNodeId ?? (document.sink.isEmpty ? nil : document.sink)
        let id = document.addNode(type: type, after: previous)
        if let previous,
           document.node(id: previous) != nil,
           document.inputCount(for: type) > 0 {
            document.connect(from: previous, to: id, input: 0)
        }
        document.sink = id
        selectedNodeId = id
        selectedNodeIds = [id]
        selectedConnectionId = nil
        syncPreviewWithDocument(markDirty: true)
        reloadInspector()
    }

    func deleteSelection() {
        if let edgeId = selectedConnectionId,
           let edge = document.connections.first(where: { $0.id == edgeId }) {
            pushUndo()
            document.disconnect(edge)
            selectedConnectionId = nil
            syncPreviewWithDocument(markDirty: true)
            return
        }
        let ids = selectedNodeIds.isEmpty
            ? (selectedNodeId.map { Set([$0]) } ?? [])
            : selectedNodeIds
        guard !ids.isEmpty else { return }
        let fallback = fallbackSelectionAfterDeleting(ids: ids)
        pushUndo()
        document.deleteNodes(ids: ids)
        selectedNodeId = fallback
        selectedNodeIds = selectedNodeId.map { Set([$0]) } ?? []
        document.sink = selectedNodeId ?? ""
        syncPreviewWithDocument(markDirty: true)
        reloadInspector()
    }

    private func fallbackSelectionAfterDeleting(ids: Set<String>) -> String? {
        let primary = selectedNodeId.flatMap { ids.contains($0) ? $0 : nil }
        if let primary,
           let upstream = document.connections
               .filter({ $0.to == primary && !ids.contains($0.from) })
               .sorted(by: { $0.input < $1.input })
               .first?.from,
           document.node(id: upstream) != nil {
            return upstream
        }

        if let upstream = document.connections
            .filter({ ids.contains($0.to) && !ids.contains($0.from) })
            .sorted(by: { $0.input < $1.input })
            .first?.from,
           document.node(id: upstream) != nil {
            return upstream
        }

        if let firstDeletedIndex = document.nodes.firstIndex(where: { ids.contains($0.id) }) {
            let before = document.nodes[..<firstDeletedIndex].last { !ids.contains($0.id) }
            if let before { return before.id }
        }

        return document.nodes.first { !ids.contains($0.id) }?.id
    }

    func connect(from: String, to: String, input: UInt32) {
        guard from != to, document.node(id: from) != nil,
              let target = document.node(id: to),
              input < document.inputCount(for: target.type) else { return }
        pushUndo()
        document.connect(from: from, to: to, input: input)
        document.sink = to
        selectedNodeId = to
        selectedNodeIds = [to]
        selectedConnectionId = nil
        syncPreviewWithDocument(markDirty: true)
    }

    func disconnect(_ edge: GraphDocumentConnection) {
        pushUndo()
        document.disconnect(edge)
        selectedConnectionId = nil
        syncPreviewWithDocument(markDirty: true)
    }

    func setSink(_ id: String) {
        guard document.node(id: id) != nil else { return }
        pushUndo()
        document.sink = id
        syncPreviewWithDocument(markDirty: true)
    }

    func resetLayout() {
        pushUndo()
        document.ui?.positions.removeAll()
        document.ensureLayout()
        markDirty()
    }

    @discardableResult
    func save(to path: String? = nil) -> Bool {
        if let path {
            graphPath = path
            engine.setGraphPath(path)
        }
        guard let graphPath else {
            saveStatus = "choose a file"
            return false
        }
        do {
            let text = try document.encodedString()
            if document.sink.isEmpty {
                guard engine.loadJSONText(text) else {
                    isDirty = true
                    saveStatus = "save blocked: \(engine.lastError())"
                    setFlatPreview(status: "no output")
                    return false
                }
                setFlatPreview(status: document.nodes.isEmpty ? "empty graph" : "no output")
                try text.write(toFile: graphPath, atomically: true, encoding: .utf8)
                isDirty = false
                saveStatus = "saved"
                return true
            }
            guard engine.loadJSONText(text) else {
                isDirty = true
                saveStatus = "save blocked: \(engine.lastError())"
                setFlatPreview(status: "invalid graph")
                return false
            }
            guard refreshTerrain() else {
                isDirty = true
                saveStatus = "save blocked: \(engine.lastError())"
                setFlatPreview(status: "invalid graph")
                return false
            }
            try text.write(toFile: graphPath, atomically: true, encoding: .utf8)
            isDirty = false
            saveStatus = "saved"
            return true
        } catch {
            saveStatus = "save failed: \(error.localizedDescription)"
            return false
        }
    }

    func load(from path: String) {
        do {
            var loaded = try GraphDocument.load(path: path)
            loaded.ensureLayout()
            document = loaded
            undoStack.removeAll()
            redoStack.removeAll()
            loadPreviewSettingsFromDocument()
            selectedNodeId = document.sink.isEmpty ? document.nodes.last?.id : document.sink
            selectedNodeIds = selectedNodeId.map { Set([$0]) } ?? []
            selectedConnectionId = nil
            graphPath = path
            engine.setGraphPath(path)
            isDirty = false
            saveStatus = "loaded"
            reloadInspector()
            syncPreviewWithDocument(markDirty: false)
        } catch {
            saveStatus = "load failed: \(error.localizedDescription)"
        }
    }

    func autosave() {
        guard isDirty, documentCanSave, let graphPath else { return }
        do {
            let text = try document.encodedString()
            try text.write(toFile: graphPath, atomically: true, encoding: .utf8)
            isDirty = false
            saveStatus = "autosaved"
        } catch {
            saveStatus = "autosave failed: \(error.localizedDescription)"
        }
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(document)
        restore(previous, status: "undo")
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(document)
        restore(next, status: "redo")
    }

    private func pushUndo() {
        guard !isRestoringHistory else { return }
        undoStack.append(document)
        if undoStack.count > 100 {
            undoStack.removeFirst(undoStack.count - 100)
        }
        redoStack.removeAll()
    }

    private func restore(_ snapshot: GraphDocument, status: String) {
        isRestoringHistory = true
        document = snapshot
        document.ensureLayout()
        loadPreviewSettingsFromDocument()
        selectedNodeId = document.sink.isEmpty ? document.nodes.last?.id : document.sink
        selectedNodeIds = selectedNodeId.map { Set([$0]) } ?? []
        selectedConnectionId = nil
        reloadInspector()
        syncPreviewWithDocument(markDirty: true)
        saveStatus = status
        isRestoringHistory = false
    }

    private func syncPreviewWithDocument(markDirty shouldMarkDirty: Bool) {
        do {
            let text = try document.encodedString()
            if document.sink.isEmpty {
                if engine.loadJSONText(text) {
                    documentCanSave = true
                    if shouldMarkDirty { markDirty() }
                    setFlatPreview(status: document.nodes.isEmpty ? "empty graph" : "no output")
                } else {
                    documentCanSave = false
                    if shouldMarkDirty {
                        isDirty = true
                        saveStatus = "preview flat: \(engine.lastError())"
                    }
                    setFlatPreview(status: "invalid graph")
                }
                return
            }
            if engine.loadJSONText(text) {
                documentCanSave = true
                if shouldMarkDirty { markDirty() }
                if !refreshTerrain() {
                    documentCanSave = false
                    if shouldMarkDirty {
                        saveStatus = "preview flat: \(engine.lastError())"
                    }
                    setFlatPreview(status: "invalid graph")
                }
            } else {
                documentCanSave = false
                if shouldMarkDirty {
                    isDirty = true
                    saveStatus = "preview flat: \(engine.lastError())"
                }
                setFlatPreview(status: "invalid graph")
            }
        } catch {
            documentCanSave = false
            if shouldMarkDirty {
                isDirty = true
                saveStatus = "preview flat: \(error.localizedDescription)"
            }
            setFlatPreview(status: "invalid graph")
        }
    }

    private func loadPreviewSettingsFromDocument() {
        let preview = document.ui?.preview ?? GraphPreviewSettings()
        displayMode = preview.displayMode
        materialPreset = preview.materialPreset
        maskOpacity = preview.maskOpacity
    }

    private func persistPreviewSettings() {
        document.setPreviewSettings(GraphPreviewSettings(
            displayMode: displayMode,
            materialPreset: materialPreset,
            maskOpacity: maskOpacity))
        documentCanSave = true
        markDirty()
    }

    private func effectiveDisplayMode(for nodeId: String) -> ViewportDisplayMode {
        guard displayMode == .auto else { return displayMode }
        guard !nodeId.isEmpty, isMaskPreviewNode(nodeId) else { return .terrain }
        return .mask
    }

    private func geometrySink(for dataSink: String, mode: ViewportDisplayMode) -> String? {
        // Terrain tools such as Gaea and World Machine treat masks/coverage maps
        // as data layered over terrain. Keep geometry from the upstream height
        // source only when the selected node is actually a mask chain. Terrain
        // nodes in material mode must keep their own output as geometry.
        if let maskGeometry = maskGeometrySink(for: dataSink) {
            return maskGeometry
        }
        return dataSink
    }

    private func isMaskPreviewNode(_ nodeId: String,
                                   visited: Set<String> = []) -> Bool {
        guard !visited.contains(nodeId),
              let node = document.node(id: nodeId) else { return false }
        if node.type == "slopemask" { return true }
        guard maskUtilityTypes.contains(node.type),
              let upstream = inputNodeId(to: nodeId, input: 0) else { return false }
        var nextVisited = visited
        nextVisited.insert(nodeId)
        return isMaskPreviewNode(upstream, visited: nextVisited)
    }

    private func maskGeometrySink(for nodeId: String,
                                  visited: Set<String> = []) -> String? {
        guard !visited.contains(nodeId),
              let node = document.node(id: nodeId) else { return nil }
        if node.type == "slopemask" {
            return inputNodeId(to: nodeId, input: 0)
        }
        guard maskUtilityTypes.contains(node.type),
              let upstream = inputNodeId(to: nodeId, input: 0) else { return nil }
        var nextVisited = visited
        nextVisited.insert(nodeId)
        return maskGeometrySink(for: upstream, visited: nextVisited) ?? upstream
    }

    private func inputNodeId(to nodeId: String, input: UInt32) -> String? {
        document.connections.first { $0.to == nodeId && $0.input == input }?.from
    }

    private func markDirty() {
        isDirty = true
        saveStatus = "unsaved"
    }
}
