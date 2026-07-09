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

struct ExportSettings: Sendable {
    enum HeightmapFormat: String, CaseIterable, Identifiable, Sendable {
        case png16
        case r16
        case pfm32

        var id: String { rawValue }

        var label: String {
            switch self {
            case .png16: return "PNG 16-bit"
            case .r16: return "RAW R16"
            case .pfm32: return "PFM 32-bit Float"
            }
        }
    }

    enum MeshFormat: String, CaseIterable, Identifiable, Sendable {
        case obj
        case fbx

        var id: String { rawValue }

        var label: String {
            switch self {
            case .obj: return "OBJ"
            case .fbx: return "FBX"
            }
        }

        var isSupported: Bool { self == .obj }
    }

    var outDir = "/private/tmp/theia-export"
    var basename = "terrain"
    var size: UInt32 = 512
    var verticalScale: Double = 1.0
    var meshStride: UInt32 = 1
    var exportHeightmap = true
    var heightmapFormat: HeightmapFormat = .png16
    var exportMesh = true
    var meshFormat: MeshFormat = .obj
    var exportHeight = true
    var exportPFM = false
    var exportNormal = false
    var exportSlope = false
    var exportMask = false
    var exportOBJ = true
}

enum ViewportTool: String, CaseIterable, Identifiable {
    case orbit
    case pan
    case zoom

    var id: String { rawValue }
}

@MainActor
final class TerrainModel: ObservableObject {
    @Published private(set) var nodes: [GraphNodeInfo] = []
    @Published private(set) var lastStats = ""
    @Published private(set) var document: GraphDocument
    @Published var selectedNodeId: String?
    @Published private(set) var selectedNodeIds: Set<String> = []
    @Published var selectedConnectionId: String?
    @Published private(set) var saveStatus = ""
    @Published private(set) var lastSavedAt: Date?
    @Published private(set) var isDirty = false
    @Published var lightAzimuthDegrees = 35.0
    @Published var lightElevationDegrees = 58.0
    @Published var wireframeEnabled = false
    @Published var displayMode: ViewportDisplayMode = .auto
    @Published var materialPreset: MaterialPreset = .natural
    @Published var maskOpacity = 0.65
    @Published var gridVisible = true
    @Published var axisVisible = true
    @Published var viewportTool: ViewportTool = .orbit
    @Published var viewportProjection: ViewportProjection = .perspective
    @Published private(set) var viewportCameraRevision: UInt64 = 0
    @Published var maskBrushEnabled = false
    @Published var maskBrushRadius = 0.035
    @Published var exportSettings = ExportSettings()
    @Published private(set) var exportStatus = ""
    @Published private(set) var isExporting = false
    @Published private(set) var diagnostics = GraphDiagnostics.empty
    @Published private(set) var recentNodeTypes: [String] = []

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
    private var isMaskBrushStrokeActive = false
    private var currentPreviewGeometry: [Float] = []
    private var currentPreviewData: [Float] = []
    private var currentPreviewWidth = 0
    private var currentPreviewHeight = 0
    private var currentEditableMaskNodeId: String?
    private let maskUtilityTypes: Set<String> = ["invert", "clamp", "remap", "blur"]
    private let maskSourceTypes: Set<String> = ["slopemask", "river"]

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
            exportSettings.basename = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        } else {
            document = GraphDocument.defaultDocument()
        }
        exportSettings.size = size == 0 ? document.resolution.width : size
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
                                       maskOpacity: maskOpacity,
                                       gridVisible: gridVisible,
                                       axisVisible: axisVisible,
                                       projectionMode: viewportProjection)
    }

    func resetCamera() {
        renderer.resetCamera()
        viewportCameraDidChange()
    }

    func setCameraPreset(_ preset: CameraPreset) {
        renderer.setCameraPreset(preset)
        viewportCameraDidChange()
    }

    func viewportCameraDidChange() {
        viewportCameraRevision &+= 1
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

    func setGridVisible(_ visible: Bool) {
        gridVisible = visible
        applyViewportSettings()
    }

    func setAxisVisible(_ visible: Bool) {
        axisVisible = visible
        applyViewportSettings()
    }

    func setViewportTool(_ tool: ViewportTool) {
        viewportTool = tool
        maskBrushEnabled = false
    }

    func setViewportProjection(_ projection: ViewportProjection) {
        viewportProjection = projection
        applyViewportSettings()
        viewportCameraDidChange()
    }

    func activeDisplayModeLabel() -> String {
        effectiveDisplayMode(for: document.sink).label
    }

    var canEditActiveMask: Bool {
        editableMaskNodeId(for: document.sink) != nil
    }

    var activeMaskEraseCount: Int {
        guard let nodeId = editableMaskNodeId(for: document.sink) else { return 0 }
        return document.maskEraseStrokes(nodeId: nodeId).count
    }

    func beginMaskBrush(at uv: CGPoint) -> Bool {
        guard maskBrushEnabled,
              let nodeId = editableMaskNodeId(for: document.sink) else { return false }
        pushUndo()
        isMaskBrushStrokeActive = true
        addMaskEraseStroke(nodeId: nodeId, uv: uv)
        return true
    }

    func continueMaskBrush(at uv: CGPoint) -> Bool {
        guard maskBrushEnabled,
              isMaskBrushStrokeActive,
              let nodeId = editableMaskNodeId(for: document.sink) else { return false }
        addMaskEraseStroke(nodeId: nodeId, uv: uv)
        return true
    }

    func endMaskBrush() {
        isMaskBrushStrokeActive = false
    }

    func clearActiveMaskErase() {
        guard let nodeId = editableMaskNodeId(for: document.sink) else { return }
        pushUndo()
        document.clearMaskEraseStrokes(nodeId: nodeId)
        documentCanSave = true
        markDirty()
        _ = refreshTerrain()
    }

    func runExport() {
        guard !isExporting else { return }
        guard !document.sink.isEmpty else {
            exportStatus = "choose a node to export"
            return
        }
        guard exportSettings.size >= 2 else {
            exportStatus = "size must be >= 2"
            return
        }
        guard exportSettings.meshStride > 0 else {
            exportStatus = "mesh stride must be > 0"
            return
        }
        guard exportSettings.verticalScale > 0 else {
            exportStatus = "vertical scale must be > 0"
            return
        }
        guard exportSettings.exportHeightmap || exportSettings.exportMesh else {
            exportStatus = "enable at least one output"
            return
        }
        guard !exportSettings.exportMesh || exportSettings.meshFormat.isSupported else {
            exportStatus = "FBX export is not available yet"
            return
        }

        let settings = exportSettings
        let sink = document.sink
        let text: String
        do {
            text = try document.encodedString()
        } catch {
            exportStatus = "export failed: \(error.localizedDescription)"
            return
        }
        isExporting = true
        exportStatus = "exporting..."

        DispatchQueue.global(qos: .userInitiated).async { [text, sink, settings] in
            let result = Self.performExport(text: text, sink: sink, settings: settings)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isExporting = false
                self.exportStatus = result
            }
        }
    }

    func reloadInspector() {
        nodes = document.nodes.map { node in
            let params = node.params.keys.sorted().map {
                GraphParameter(nodeId: node.id, nodeType: node.type,
                               name: $0, value: node.params[$0] ?? 0)
            }
            return GraphNodeInfo(id: node.id, type: node.type, params: params)
        }
        refreshDiagnostics()
    }

    func refreshDiagnostics() {
        diagnostics = GraphDiagnostics.analyze(document)
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
        if param == "particles", value >= 20000 {
            lastStats += " - high particle count may preview slowly"
        }
        reloadInspector()
    }

    func resetParam(nodeId: String, param: String) {
        guard let node = document.node(id: nodeId),
              let value = GraphDocument.defaultParams(for: node.type)[param] else { return }
        apply(nodeId: nodeId, param: param, value: value)
    }

    func resetAllParams(nodeId: String) {
        guard let node = document.node(id: nodeId) else { return }
        pushUndo()
        let defaults = GraphDocument.defaultParams(for: node.type)
        for (key, value) in defaults {
            document.setParam(nodeId: nodeId, key: key, value: value)
            _ = theia.graph_set_param(engine.handle, nodeId, key, value)
        }
        syncPreviewWithDocument(markDirty: true)
        reloadInspector()
    }

    @discardableResult
    func refreshTerrain() -> Bool {
        let dataSink = document.sink
        guard !dataSink.isEmpty else {
            setFlatPreview(status: document.nodes.isEmpty ? "empty graph" : "no output")
            return true
        }

        let requestedMode = displayMode
        let mode = effectiveDisplayMode(for: dataSink)
        if previewRiverCarveWithEditedMask(dataSink: dataSink, mode: mode) {
            return true
        }
        let geometrySink = geometrySink(for: dataSink,
                                        requestedMode: requestedMode,
                                        renderMode: mode) ?? dataSink
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
        currentPreviewGeometry = geometry.heights
        currentPreviewData = data.heights
        currentPreviewWidth = w
        currentPreviewHeight = h
        currentEditableMaskNodeId = editableMaskNodeId(for: dataSink)
        renderCachedPreview()
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
        currentPreviewGeometry = flat
        currentPreviewData = flat
        currentPreviewWidth = dim
        currentPreviewHeight = dim
        currentEditableMaskNodeId = nil
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

    func addNode(type: String, at position: GraphNodePosition? = nil) {
        pushUndo()
        recordRecentNodeType(type)
        let previous = selectedNodeId ?? (document.sink.isEmpty ? nil : document.sink)
        let id = document.addNode(type: type, after: previous, at: position)
        if type == "rivercarve",
           let previous,
           document.node(id: previous)?.type == "river",
           let terrain = document.upstreamNodeId(to: previous, input: 0) {
            document.connect(from: terrain, to: id, input: 0)
            document.connect(from: previous, to: id, input: 1)
        } else if let previous,
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

    func addQuickStart(kind: String) {
        pushUndo()

        let selected: String
        let createdTypes: [String]
        switch kind {
        case "ridged":
            selected = document.addNode(type: "ridged",
                                        at: GraphNodePosition(x: 120, y: 120))
            createdTypes = ["ridged"]
        case "terrace":
            let perlin = document.addNode(type: "perlin",
                                          at: GraphNodePosition(x: 80, y: 120))
            let terrace = document.addNode(type: "terrace",
                                           at: GraphNodePosition(x: 300, y: 120))
            document.connect(from: perlin, to: terrace, input: 0)
            selected = terrace
            createdTypes = ["perlin", "terrace"]
        case "river":
            let perlin = document.addNode(type: "perlin",
                                          at: GraphNodePosition(x: 80, y: 120))
            let river = document.addNode(type: "river",
                                         at: GraphNodePosition(x: 300, y: 168))
            let carve = document.addNode(type: "rivercarve",
                                         at: GraphNodePosition(x: 520, y: 120))
            document.connect(from: perlin, to: river, input: 0)
            document.connect(from: perlin, to: carve, input: 0)
            document.connect(from: river, to: carve, input: 1)
            selected = carve
            createdTypes = ["perlin", "river", "rivercarve"]
        default:
            selected = document.addNode(type: "perlin",
                                        at: GraphNodePosition(x: 120, y: 120))
            createdTypes = ["perlin"]
        }

        createdTypes.forEach(recordRecentNodeType)
        document.sink = selected
        selectedNodeId = selected
        selectedNodeIds = [selected]
        selectedConnectionId = nil
        syncPreviewWithDocument(markDirty: true)
        reloadInspector()
    }

    private func recordRecentNodeType(_ type: String) {
        recentNodeTypes.removeAll { $0 == type }
        recentNodeTypes.insert(type, at: 0)
        if recentNodeTypes.count > 6 {
            recentNodeTypes.removeLast(recentNodeTypes.count - 6)
        }
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

    func duplicateSelection() {
        let ids = selectedNodeIds.isEmpty
            ? (selectedNodeId.map { Set([$0]) } ?? [])
            : selectedNodeIds
        guard !ids.isEmpty else { return }
        pushUndo()
        let duplicated = document.duplicateNodes(ids: ids)
        guard !duplicated.isEmpty else { return }
        selectedNodeId = duplicated.last
        selectedNodeIds = Set(duplicated)
        selectedConnectionId = nil
        document.sink = selectedNodeId ?? document.sink
        syncPreviewWithDocument(markDirty: true)
        reloadInspector()
    }

    func selectUpstreamOfSelection() {
        guard let id = selectedNodeId,
              let edge = document.connections
                .filter({ $0.to == id })
                .sorted(by: { $0.input < $1.input })
                .first else { return }
        selectNode(edge.from)
    }

    func selectDownstreamOfSelection() {
        guard let id = selectedNodeId,
              let edge = document.connections
                .filter({ $0.from == id })
                .sorted(by: { $0.to < $1.to })
                .first else { return }
        selectNode(edge.to)
    }

    func selectDiagnosticIssue(_ issue: GraphDiagnosticIssue) {
        if let node = issue.node, document.node(id: node) != nil {
            selectNode(node)
        } else if let edgeId = issue.edge {
            selectConnection(edgeId)
        }
    }

    func diagnosticSeverity(for nodeId: String) -> String? {
        diagnostics.issueSeverity(for: nodeId)
    }

    func missingDiagnosticInputs(for nodeId: String) -> Set<UInt32> {
        diagnostics.missingInputs(for: nodeId)
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
        if target.type == "rivercarve",
           input == 0,
           document.node(id: from)?.type == "river",
           let terrain = document.upstreamNodeId(to: from, input: 0) {
            document.connect(from: terrain, to: to, input: 0)
            document.connect(from: from, to: to, input: 1)
        } else {
            document.connect(from: from, to: to, input: input)
            document.repairRiverCarveConnections()
        }
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
                lastSavedAt = Date()
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
            lastSavedAt = Date()
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
            exportSettings.basename = URL(fileURLWithPath: path)
                .deletingPathExtension()
                .lastPathComponent
            isDirty = false
            saveStatus = "loaded"
            lastSavedAt = Self.fileModifiedDate(path: path)
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
            lastSavedAt = Date()
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
        refreshDiagnostics()
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

    private func geometrySink(for dataSink: String,
                              requestedMode: ViewportDisplayMode,
                              renderMode: ViewportDisplayMode) -> String? {
        // Terrain tools such as Gaea and World Machine treat masks/coverage maps
        // as data layered over terrain. Keep geometry from the upstream height
        // source whenever the selected node is a mask chain. Manual display
        // modes still apply: height/slope/normal inspect that upstream terrain,
        // while mask/material use the selected mask as the data layer.
        _ = requestedMode
        _ = renderMode
        if let maskGeometry = maskGeometrySink(for: dataSink) {
            return maskGeometry
        }
        return dataSink
    }

    private func editableMaskNodeId(for nodeId: String) -> String? {
        guard !nodeId.isEmpty, isMaskPreviewNode(nodeId) else { return nil }
        return nodeId
    }

    private func addMaskEraseStroke(nodeId: String, uv: CGPoint) {
        let stroke = GraphMaskEraseStroke(
            x: min(max(Double(uv.x), 0), 1),
            y: min(max(Double(uv.y), 0), 1),
            radius: min(max(maskBrushRadius, 0.003), 0.20),
            strength: 1.0)
        document.addMaskEraseStroke(nodeId: nodeId, stroke: stroke)
        documentCanSave = true
        markDirty()
        renderCachedPreview()
    }

    private func renderCachedPreview() {
        guard currentPreviewWidth > 1,
              currentPreviewHeight > 1,
              !currentPreviewGeometry.isEmpty,
              !currentPreviewData.isEmpty else { return }
        var data = currentPreviewData
        if let nodeId = currentEditableMaskNodeId {
            applyMaskEraseStrokes(to: &data, nodeId: nodeId,
                                  width: currentPreviewWidth,
                                  height: currentPreviewHeight)
        }
        renderer.setPreview(heights: currentPreviewGeometry, data: data,
                            width: currentPreviewWidth, height: currentPreviewHeight)
    }

    private func applyMaskEraseStrokes(to values: inout [Float], nodeId: String,
                                       width: Int, height: Int) {
        let strokes = document.maskEraseStrokes(nodeId: nodeId)
        guard !strokes.isEmpty, width > 1, height > 1 else { return }
        for stroke in strokes {
            let radius = max(0.0001, stroke.radius)
            let r2 = radius * radius
            let minX = max(0, Int(floor((stroke.x - radius) * Double(width - 1))))
            let maxX = min(width - 1, Int(ceil((stroke.x + radius) * Double(width - 1))))
            let minY = max(0, Int(floor((stroke.y - radius) * Double(height - 1))))
            let maxY = min(height - 1, Int(ceil((stroke.y + radius) * Double(height - 1))))
            for y in minY...maxY {
                let vy = Double(y) / Double(height - 1)
                for x in minX...maxX {
                    let ux = Double(x) / Double(width - 1)
                    let dx = ux - stroke.x
                    let dy = vy - stroke.y
                    let d2 = dx * dx + dy * dy
                    if d2 > r2 { continue }
                    let t = 1.0 - min(max(sqrt(d2) / radius, 0), 1)
                    let falloff = t * t * (3.0 - 2.0 * t)
                    let erase = Float(min(max(stroke.strength * falloff, 0), 1))
                    let i = y * width + x
                    values[i] = max(0, values[i] * (1 - erase))
                }
            }
        }
    }

    private func previewRiverCarveWithEditedMask(dataSink: String,
                                                 mode: ViewportDisplayMode) -> Bool {
        guard let node = document.node(id: dataSink),
              node.type == "rivercarve",
              let terrainSink = inputNodeId(to: dataSink, input: 0),
              let maskSink = inputNodeId(to: dataSink, input: 1),
              !document.maskEraseStrokes(nodeId: maskSink).isEmpty else {
            return false
        }
        guard let terrain = engine.evaluate(size: size, sink: terrainSink),
              let mask = engine.evaluate(size: size, sink: maskSink) else {
            lastStats = engine.lastError()
            return true
        }
        let w = Int(terrain.result.width)
        let h = Int(terrain.result.height)
        guard mask.heights.count == terrain.heights.count else {
            lastStats = "rivercarve mask size mismatch"
            return true
        }
        var editedMask = mask.heights
        applyMaskEraseStrokes(to: &editedMask, nodeId: maskSink, width: w, height: h)
        let carved = Self.carveRiverPreview(terrain: terrain.heights,
                                            mask: editedMask,
                                            width: w,
                                            height: h,
                                            depth: node.params["depth"] ?? 0.45,
                                            downcutting: node.params["downcutting"] ?? 0.55,
                                            valleyWidth: node.params["riverValleyWidth"] ?? 2.0,
                                            shorelineWidth: node.params["shorelineWidth"] ?? 2.0,
                                            shorelineSharpness: node.params["shorelineSharpness"] ?? 0.45)
        currentPreviewGeometry = carved
        currentPreviewData = carved
        currentPreviewWidth = w
        currentPreviewHeight = h
        currentEditableMaskNodeId = nil
        renderer.setPreview(heights: carved, data: carved, width: w, height: h)
        applyViewportSettings(displayMode: mode == .auto ? .terrain : mode)
        lastStats = "nodes \(terrain.result.evaluated + mask.result.evaluated), reused \(terrain.result.reused + mask.result.reused)"
        return true
    }

    private static func carveRiverPreview(terrain: [Float], mask: [Float],
                                          width: Int, height: Int,
                                          depth: Double, downcutting: Double,
                                          valleyWidth: Double,
                                          shorelineWidth: Double,
                                          shorelineSharpness: Double) -> [Float] {
        let clampedMask = mask.map { min(max($0, 0), 1) }
        let radius = max(1, Int(ceil(1.0 + min(max(valleyWidth, 0), 12) * 2.0)))
        let valley = boxBlur(clampedMask, width: width, height: height,
                             radius: radius, passes: 2)
        let shoreRadius = max(1, Int(ceil(min(max(shorelineWidth, 0), 12))))
        let shoreEnvelope = boxBlur(clampedMask, width: width, height: height,
                                    radius: shoreRadius, passes: 3)
            .map { min(max($0, 0), 1) }
        let sharpness = Float(min(max(shorelineSharpness, 0), 1))
        let d = Float(min(max(depth, 0), 1))
        let down = Float(min(max(downcutting, 0), 1))
        let channelCut = d * (0.035 + 0.18 * down)
        let valleyCut = d * (0.010 + 0.045 * down)
        let rawChannelMix = shorelineWidth <= 0 ? Float(1.0) : Float(0.08) + sharpness * Float(0.42)
        let shoreExponent = Float(0.50) + sharpness * Float(1.25)
        var out = terrain
        for i in out.indices {
            let base = min(max(terrain[i], 0), 1)
            let softenedChannel = Float(pow(Double(shoreEnvelope[i]), Double(shoreExponent)))
            let carveProfile = min(max(softenedChannel * (1 - rawChannelMix) +
                                       clampedMask[i] * rawChannelMix, 0), 1)
            out[i] = min(max(base - channelCut * carveProfile - valleyCut * valley[i], 0), 1)
        }
        return out
    }

    private static func boxBlur(_ input: [Float], width: Int, height: Int,
                                radius: Int, passes: Int) -> [Float] {
        if radius <= 0 || passes <= 0 { return input }
        var a = input
        var b = input
        for _ in 0..<passes {
            for y in 0..<height {
                for x in 0..<width {
                    var sum: Float = 0
                    var count: Float = 0
                    let x0 = max(0, x - radius)
                    let x1 = min(width - 1, x + radius)
                    for nx in x0...x1 {
                        sum += a[y * width + nx]
                        count += 1
                    }
                    b[y * width + x] = sum / max(1, count)
                }
            }
            for y in 0..<height {
                let y0 = max(0, y - radius)
                let y1 = min(height - 1, y + radius)
                for x in 0..<width {
                    var sum: Float = 0
                    var count: Float = 0
                    for ny in y0...y1 {
                        sum += b[ny * width + x]
                        count += 1
                    }
                    a[y * width + x] = sum / max(1, count)
                }
            }
        }
        return a
    }

    private func isMaskPreviewNode(_ nodeId: String,
                                   visited: Set<String> = []) -> Bool {
        guard !visited.contains(nodeId),
              let node = document.node(id: nodeId) else { return false }
        if maskSourceTypes.contains(node.type) { return true }
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
        if maskSourceTypes.contains(node.type) {
            return inputNodeId(to: nodeId, input: 0)
        }
        guard maskUtilityTypes.contains(node.type),
              let upstream = inputNodeId(to: nodeId, input: 0) else { return nil }
        var nextVisited = visited
        nextVisited.insert(nodeId)
        return maskGeometrySink(for: upstream, visited: nextVisited)
    }

    private func inputNodeId(to nodeId: String, input: UInt32) -> String? {
        document.connections.first { $0.to == nodeId && $0.input == input }?.from
    }

    private nonisolated static func performExport(text: String, sink: String,
                                                  settings: ExportSettings) -> String {
        do {
            try FileManager.default.createDirectory(atPath: settings.outDir,
                                                    withIntermediateDirectories: true)
        } catch {
            return "export failed: \(error.localizedDescription)"
        }
        guard let g = theia.graph_create() else { return "export failed: graph create" }
        defer { theia.graph_destroy(g) }
        guard theia.graph_load_json_text(g, text) else {
            let err = readCxxString { theia.graph_last_error(g, $0, $1) }
            return "export failed: \(err)"
        }

        func path(_ suffix: String, enabled: Bool) -> String {
            guard enabled else { return "" }
            return URL(fileURLWithPath: settings.outDir)
                .appendingPathComponent("\(settings.basename)\(suffix)")
                .path
        }

        let writeHeightPNG = settings.exportHeightmap && settings.heightmapFormat == .png16
        let writePFM = settings.exportHeightmap && settings.heightmapFormat == .pfm32
        let writeRawR16 = settings.exportHeightmap && settings.heightmapFormat == .r16
        let writeOBJ = settings.exportMesh && settings.meshFormat == .obj

        let r = theia.graph_export(
            g, sink, settings.size, settings.size,
            path("_height.png", enabled: writeHeightPNG),
            path(".pfm", enabled: writePFM),
            "",
            "",
            "",
            path(".obj", enabled: writeOBJ),
            Float(settings.verticalScale),
            settings.meshStride)
        guard r.ok else {
            let err = readCxxString { theia.graph_last_error(g, $0, $1) }
            return "export failed: \(err)"
        }
        if writeRawR16 {
            let count = Int(r.width) * Int(r.height)
            guard count > 0 else { return "export failed: empty heightfield" }
            var heights = [Float](repeating: 0, count: count)
            let rawEval = heights.withUnsafeMutableBufferPointer {
                theia.graph_evaluate_heights(g, sink, r.width, r.height,
                                             $0.baseAddress, $0.count)
            }
            guard rawEval.ok else {
                let err = readCxxString { theia.graph_last_error(g, $0, $1) }
                return "export failed: \(err)"
            }
            let rawPath = path("_height.r16", enabled: true)
            do {
                try writeR16Heightmap(heights, path: rawPath)
            } catch {
                return "export failed: \(error.localizedDescription)"
            }
        }
        return "exported \(settings.basename) \(r.width)x\(r.height)"
    }

    private nonisolated static func writeR16Heightmap(_ heights: [Float],
                                                      path: String) throws {
        var data = Data()
        data.reserveCapacity(heights.count * MemoryLayout<UInt16>.size)
        for height in heights {
            let normalized = min(1.0, max(0.0, height.isFinite ? height : 0.0))
            var sample = UInt16((normalized * Float(UInt16.max)).rounded())
                .littleEndian
            withUnsafeBytes(of: &sample) { data.append(contentsOf: $0) }
        }
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func markDirty() {
        isDirty = true
        saveStatus = "unsaved"
    }

    private static func fileModifiedDate(path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
    }
}
