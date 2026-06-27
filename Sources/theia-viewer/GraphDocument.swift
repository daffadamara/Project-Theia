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

struct GraphDocumentUI: Codable {
    var positions: [String: GraphNodePosition] = [:]
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
    }

    mutating func ensureNodeDefaults() {
        for index in nodes.indices {
            let defaults = Self.defaultParams(for: nodes[index].type)
            nodes[index].params = defaults.merging(nodes[index].params) { _, saved in saved }
        }
    }

    func encodedString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        return String(decoding: data, as: UTF8.self)
    }

    mutating func addNode(type: String, after previousId: String? = nil) -> String {
        let base = type
        var id = base
        var suffix = 1
        while nodes.contains(where: { $0.id == id }) {
            id = "\(base)\(suffix)"
            suffix += 1
        }
        nodes.append(GraphDocumentNode(id: id, type: type, params: Self.defaultParams(for: type)))
        if ui == nil { ui = GraphDocumentUI() }
        if let previousId, let previous = ui?.positions[previousId] {
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

    mutating func connect(from: String, to: String, input: UInt32) {
        connections.removeAll { $0.to == to && $0.input == input }
        let edge = GraphDocumentConnection(from: from, to: to, input: input)
        if !connections.contains(edge) {
            connections.append(edge)
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

    static func defaultParams(for type: String) -> [String: Double] {
        var result: [String: Double] = [:]
        let count = theia.graph_default_param_count(type)
        for i in 0..<count {
            let name = readCxxString { theia.graph_default_param_name(type, i, $0, $1) }
            result[name] = theia.graph_default_param_value(type, name, 0)
        }
        return result
    }
}
