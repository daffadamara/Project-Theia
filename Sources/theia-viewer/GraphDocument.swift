import Foundation
import TheiaCore

struct GraphResolution: Codable {
    var width: UInt32
    var height: UInt32
}

struct GraphDocumentNode: Codable, Identifiable {
    var id: String
    var type: String
    var params: [String: Double]
}

struct GraphDocumentConnection: Codable, Identifiable, Equatable {
    var from: String
    var to: String
    var input: UInt32

    var id: String { "\(from)->\(to).\(input)" }
}

struct GraphNodePosition: Codable, Equatable {
    var x: Double
    var y: Double
}

struct GraphMaskEraseStroke: Codable, Equatable {
    var x: Double
    var y: Double
    var radius: Double
    var strength: Double
}

enum ViewportDisplayMode: String, CaseIterable, Identifiable {
    case auto
    case terrain
    case height
    case mask
    case slope
    case normal
    case material

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "auto"
        case .terrain: return "terrain"
        case .height: return "height"
        case .mask: return "mask"
        case .slope: return "slope"
        case .normal: return "normal"
        case .material: return "material"
        }
    }

    var rendererMode: UInt32 {
        switch self {
        case .auto, .terrain: return 0
        case .height: return 1
        case .mask: return 2
        case .slope: return 3
        case .normal: return 4
        case .material: return 5
        }
    }
}

extension ViewportDisplayMode: Codable {
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = ViewportDisplayMode(rawValue: value) ?? .auto
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

enum MaterialPreset: String, CaseIterable, Identifiable {
    case natural
    case alpine
    case arid
    case analysis

    var id: String { rawValue }

    var label: String { rawValue }

    var rendererPreset: UInt32 {
        switch self {
        case .natural: return 0
        case .alpine: return 1
        case .arid: return 2
        case .analysis: return 3
        }
    }
}

extension MaterialPreset: Codable {
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = MaterialPreset(rawValue: value) ?? .natural
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

struct GraphPreviewSettings: Codable {
    var displayMode: ViewportDisplayMode = .auto
    var materialPreset: MaterialPreset = .natural
    var maskOpacity: Double = 0.65

    enum CodingKeys: String, CodingKey {
        case displayMode, materialPreset, maskOpacity
    }

    init(displayMode: ViewportDisplayMode = .auto,
         materialPreset: MaterialPreset = .natural,
         maskOpacity: Double = 0.65) {
        self.displayMode = displayMode
        self.materialPreset = materialPreset
        self.maskOpacity = min(max(maskOpacity, 0), 1)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        displayMode = try c.decodeIfPresent(ViewportDisplayMode.self,
                                            forKey: .displayMode) ?? .auto
        materialPreset = try c.decodeIfPresent(MaterialPreset.self,
                                               forKey: .materialPreset) ?? .natural
        let opacity = try c.decodeIfPresent(Double.self, forKey: .maskOpacity) ?? 0.65
        maskOpacity = min(max(opacity, 0), 1)
    }
}

struct GraphDocumentUI: Codable {
    var positions: [String: GraphNodePosition] = [:]
    var preview = GraphPreviewSettings()
    var maskErases: [String: [GraphMaskEraseStroke]] = [:]

    enum CodingKeys: String, CodingKey {
        case positions, preview, maskErases
    }

    init(positions: [String: GraphNodePosition] = [:],
         preview: GraphPreviewSettings = GraphPreviewSettings(),
         maskErases: [String: [GraphMaskEraseStroke]] = [:]) {
        self.positions = positions
        self.preview = preview
        self.maskErases = maskErases
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        positions = try c.decodeIfPresent([String: GraphNodePosition].self,
                                          forKey: .positions) ?? [:]
        preview = try c.decodeIfPresent(GraphPreviewSettings.self,
                                        forKey: .preview) ?? GraphPreviewSettings()
        maskErases = try c.decodeIfPresent([String: [GraphMaskEraseStroke]].self,
                                           forKey: .maskErases) ?? [:]
    }
}

struct GraphDocument: Codable {
    var resolution: GraphResolution
    var sink: String
    var nodes: [GraphDocumentNode]
    var connections: [GraphDocumentConnection]
    var ui: GraphDocumentUI?

    enum CodingKeys: String, CodingKey {
        case resolution, sink, nodes, connections, ui
    }

    init(resolution: GraphResolution,
         sink: String,
         nodes: [GraphDocumentNode],
         connections: [GraphDocumentConnection],
         ui: GraphDocumentUI?) {
        self.resolution = resolution
        self.sink = sink
        self.nodes = nodes
        self.connections = connections
        self.ui = ui
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        resolution = try c.decodeIfPresent(GraphResolution.self, forKey: .resolution)
            ?? GraphResolution(width: 512, height: 512)
        sink = try c.decodeIfPresent(String.self, forKey: .sink) ?? ""
        nodes = try c.decodeIfPresent([GraphDocumentNode].self, forKey: .nodes) ?? []
        connections = try c.decodeIfPresent([GraphDocumentConnection].self, forKey: .connections) ?? []
        ui = try c.decodeIfPresent(GraphDocumentUI.self, forKey: .ui)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(resolution, forKey: .resolution)
        if !sink.isEmpty {
            try c.encode(sink, forKey: .sink)
        }
        try c.encode(nodes, forKey: .nodes)
        try c.encode(connections, forKey: .connections)
        if let ui {
            try c.encode(ui, forKey: .ui)
        }
    }

    static func load(path: String) throws -> GraphDocument {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        var doc = try JSONDecoder().decode(GraphDocument.self, from: data)
        doc.ensureNodeDefaults()
        doc.ensureLayout()
        return doc
    }

    static func defaultDocument() -> GraphDocument {
        var doc = GraphDocument.emptyDocument()
        doc.ensureLayout()
        return doc
    }

    static func emptyDocument(width: UInt32 = 512, height: UInt32 = 512) -> GraphDocument {
        GraphDocument(resolution: GraphResolution(width: width, height: height),
                      sink: "",
                      nodes: [],
                      connections: [],
                      ui: GraphDocumentUI())
    }

    mutating func ensureLayout() {
        ensureNodeDefaults()
        repairRiverCarveConnections()
        if ui == nil { ui = GraphDocumentUI() }
        var positions = ui?.positions ?? [:]
        for (index, node) in nodes.enumerated() where positions[node.id] == nil {
            positions[node.id] = GraphNodePosition(x: 80 + Double(index % 4) * 210,
                                                   y: 80 + Double(index / 4) * 150)
        }
        for key in Array(positions.keys) where !nodes.contains(where: { $0.id == key }) {
            positions.removeValue(forKey: key)
        }
        ui?.positions = positions
        if let eraseKeys = ui?.maskErases.keys {
            for key in Array(eraseKeys) where !nodes.contains(where: { $0.id == key }) {
                ui?.maskErases.removeValue(forKey: key)
            }
        }
    }

    mutating func ensureNodeDefaults() {
        for index in nodes.indices {
            let defaults = Self.defaultParams(for: nodes[index].type)
            nodes[index].params = defaults.merging(nodes[index].params) { _, saved in saved }
            migrateLegacySlopeMaskDefaults(index: index)
            migrateLegacyRiverMaskParams(index: index)
        }
    }

    private mutating func migrateLegacyRiverMaskParams(index: Int) {
        guard nodes[index].type == "river" else { return }
        for key in ["depth", "downcutting", "renderSurface", "riverValleyWidth"] {
            nodes[index].params.removeValue(forKey: key)
        }
    }

    private mutating func migrateLegacySlopeMaskDefaults(index: Int) {
        guard nodes[index].type == "slopemask" else { return }
        let params = nodes[index].params
        let low = params["low"] ?? 15.0
        let high = params["high"] ?? 55.0
        let heightScale = params["heightScale"] ?? 1.0
        if (low >= -1.0 && low <= 1.0 && high >= -1.0 && high <= 1.0) ||
            high <= low ||
            heightScale == 64.0 {
            nodes[index].params["low"] = 15.0
            nodes[index].params["high"] = 55.0
            nodes[index].params["heightScale"] = 1.0
        }
    }

    func encodedString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        return String(decoding: data, as: UTF8.self)
    }

    mutating func addNode(type: String, after previousId: String? = nil,
                          at position: GraphNodePosition? = nil) -> String {
        let id = uniqueNodeId(base: type)
        nodes.append(GraphDocumentNode(id: id, type: type, params: Self.defaultParams(for: type)))
        if ui == nil { ui = GraphDocumentUI() }
        if let position {
            ui?.positions[id] = position
        } else if let previousId, let previous = ui?.positions[previousId] {
            ui?.positions[id] = GraphNodePosition(x: previous.x + 220, y: previous.y)
        } else if let last = nodes.dropLast().last,
                  let previous = ui?.positions[last.id] {
            ui?.positions[id] = GraphNodePosition(x: previous.x + 220, y: previous.y)
        } else {
            ui?.positions[id] = GraphNodePosition(x: 120, y: 120)
        }
        if sink.isEmpty && inputCount(for: type) == 0 {
            sink = id
        }
        return id
    }

    mutating func duplicateNodes(ids: Set<String>) -> [String] {
        let originals = nodes.filter { ids.contains($0.id) }
        guard !originals.isEmpty else { return [] }
        if ui == nil { ui = GraphDocumentUI() }
        var idMap: [String: String] = [:]
        var duplicatedIds: [String] = []
        for original in originals {
            let newId = uniqueNodeId(base: "\(original.id)Copy")
            idMap[original.id] = newId
            duplicatedIds.append(newId)
            nodes.append(GraphDocumentNode(id: newId,
                                           type: original.type,
                                           params: original.params))
            let p = ui?.positions[original.id] ?? GraphNodePosition(x: 120, y: 120)
            ui?.positions[newId] = GraphNodePosition(x: p.x + 36, y: p.y + 36)
        }
        for edge in connections where ids.contains(edge.from) && ids.contains(edge.to) {
            guard let from = idMap[edge.from], let to = idMap[edge.to] else { continue }
            connections.append(GraphDocumentConnection(from: from, to: to, input: edge.input))
        }
        if let oldSink = ids.contains(sink) ? sink : originals.last?.id,
           let newSink = idMap[oldSink] {
            sink = newSink
        }
        return duplicatedIds
    }

    mutating func deleteNode(id: String) {
        nodes.removeAll { $0.id == id }
        connections.removeAll { $0.from == id || $0.to == id }
        ui?.positions.removeValue(forKey: id)
        if sink == id { sink = nodes.last?.id ?? "" }
    }

    mutating func deleteNodes(ids: Set<String>) {
        nodes.removeAll { ids.contains($0.id) }
        connections.removeAll { ids.contains($0.from) || ids.contains($0.to) }
        for id in ids {
            ui?.positions.removeValue(forKey: id)
            ui?.maskErases.removeValue(forKey: id)
        }
        if ids.contains(sink) {
            sink = nodes.last?.id ?? ""
        }
    }

    mutating func setParam(nodeId: String, key: String, value: Double) {
        guard let idx = nodes.firstIndex(where: { $0.id == nodeId }) else { return }
        nodes[idx].params[key] = value
    }

    mutating func setPosition(nodeId: String, x: Double, y: Double) {
        if ui == nil { ui = GraphDocumentUI() }
        ui?.positions[nodeId] = GraphNodePosition(x: x, y: y)
    }

    mutating func setPreviewSettings(_ settings: GraphPreviewSettings) {
        if ui == nil { ui = GraphDocumentUI() }
        ui?.preview = settings
    }

    mutating func addMaskEraseStroke(nodeId: String, stroke: GraphMaskEraseStroke) {
        if ui == nil { ui = GraphDocumentUI() }
        ui?.maskErases[nodeId, default: []].append(stroke)
    }

    mutating func clearMaskEraseStrokes(nodeId: String) {
        ui?.maskErases.removeValue(forKey: nodeId)
    }

    func maskEraseStrokes(nodeId: String) -> [GraphMaskEraseStroke] {
        ui?.maskErases[nodeId] ?? []
    }

    mutating func connect(from: String, to: String, input: UInt32) {
        connections.removeAll { $0.to == to && $0.input == input }
        let edge = GraphDocumentConnection(from: from, to: to, input: input)
        if !connections.contains(edge) {
            connections.append(edge)
        }
    }

    mutating func repairRiverCarveConnections() {
        for carve in nodes where carve.type == "rivercarve" {
            guard let misplacedMask = connections.first(where: {
                $0.to == carve.id && $0.input == 0 && node(id: $0.from)?.type == "river"
            }) else { continue }
            guard let upstreamTerrain = upstreamNodeId(to: misplacedMask.from, input: 0)
            else { continue }
            connect(from: upstreamTerrain, to: carve.id, input: 0)
            connect(from: misplacedMask.from, to: carve.id, input: 1)
        }
    }

    mutating func disconnect(_ edge: GraphDocumentConnection) {
        connections.removeAll { $0 == edge }
    }

    func inputCount(for type: String) -> UInt32 {
        theia.graph_node_type_input_count(type)
    }

    func node(id: String) -> GraphDocumentNode? {
        nodes.first { $0.id == id }
    }

    func upstreamNodeId(to nodeId: String, input: UInt32) -> String? {
        connections.first { $0.to == nodeId && $0.input == input }?.from
    }

    static func defaultParams(for type: String) -> [String: Double] {
        var result: [String: Double] = [:]
        let count = theia.graph_default_param_count(type)
        for i in 0..<count {
            let name = readCxxString { theia.graph_default_param_name(type, i, $0, $1) }
            result[name] = theia.graph_default_param_value(type, name, 0)
        }
        return result
    }

    private func uniqueNodeId(base: String) -> String {
        var id = base
        var suffix = 1
        while nodes.contains(where: { $0.id == id }) {
            id = "\(base)\(suffix)"
            suffix += 1
        }
        return id
    }
}
