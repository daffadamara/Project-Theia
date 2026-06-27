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

    static func load(path: String) throws -> GraphDocument {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        var doc = try JSONDecoder().decode(GraphDocument.self, from: data)
        doc.ensureLayout()
        return doc
    }

    static func defaultDocument() -> GraphDocument {
        var doc = GraphDocument(
            resolution: GraphResolution(width: 512, height: 512),
            sink: "out",
            nodes: [
                GraphDocumentNode(id: "base", type: "perlin",
                                  params: defaultParams(for: "perlin")),
                GraphDocumentNode(id: "ero", type: "hydraulic",
                                  params: defaultParams(for: "hydraulic").merging(
                                    ["iterations": 150]) { _, override in override }),
                GraphDocumentNode(id: "settle", type: "thermal",
                                  params: defaultParams(for: "thermal")),
                GraphDocumentNode(id: "out", type: "normalize",
                                  params: defaultParams(for: "normalize")),
            ],
            connections: [
                GraphDocumentConnection(from: "base", to: "ero", input: 0),
                GraphDocumentConnection(from: "ero", to: "settle", input: 0),
                GraphDocumentConnection(from: "settle", to: "out", input: 0),
            ],
            ui: GraphDocumentUI())
        doc.ensureLayout()
        return doc
    }

    mutating func ensureLayout() {
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

    func encodedString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        return String(decoding: data, as: UTF8.self)
    }

    mutating func addNode(type: String) -> String {
        let base = type
        var id = base
        var suffix = 1
        while nodes.contains(where: { $0.id == id }) {
            id = "\(base)\(suffix)"
            suffix += 1
        }
        nodes.append(GraphDocumentNode(id: id, type: type, params: Self.defaultParams(for: type)))
        if ui == nil { ui = GraphDocumentUI() }
        ui?.positions[id] = GraphNodePosition(x: 120, y: 120)
        return id
    }

    mutating func deleteNode(id: String) {
        nodes.removeAll { $0.id == id }
        connections.removeAll { $0.from == id || $0.to == id }
        ui?.positions.removeValue(forKey: id)
        if sink == id { sink = nodes.last?.id ?? "" }
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
