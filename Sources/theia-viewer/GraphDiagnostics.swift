import Foundation
import TheiaCore

struct GraphDiagnosticSummary: Codable, Equatable {
    var nodes: Int = 0
    var connections: Int = 0
    var errors: Int = 0
    var warnings: Int = 0
    var sink: String = ""
}

struct GraphDiagnosticIssue: Codable, Identifiable, Equatable {
    var severity: String
    var code: String
    var message: String
    var node: String?
    var edge: String?
    var input: UInt32?

    var id: String {
        [severity, code, node ?? "", edge ?? "", input.map(String.init) ?? "", message]
            .joined(separator: "|")
    }

    var isError: Bool { severity == "error" }
    var isWarning: Bool { severity == "warning" }
}

struct GraphDiagnostics: Codable, Equatable {
    var ok: Bool
    var summary: GraphDiagnosticSummary
    var issues: [GraphDiagnosticIssue]

    static let empty = GraphDiagnostics(ok: true,
                                        summary: GraphDiagnosticSummary(),
                                        issues: [])

    private static let advisoryOnlyCodes: Set<String> = [
        "orphan_node",
        "heavy_simulation"
    ]

    var authoringIssues: [GraphDiagnosticIssue] {
        issues.filter { !Self.advisoryOnlyCodes.contains($0.code) }
    }

    var authoringErrorCount: Int {
        authoringIssues.filter(\.isError).count
    }

    var authoringWarningCount: Int {
        authoringIssues.filter(\.isWarning).count
    }

    var hasErrors: Bool { summary.errors > 0 }
    var hasWarnings: Bool { summary.warnings > 0 }

    func issues(for nodeId: String) -> [GraphDiagnosticIssue] {
        authoringIssues.filter { $0.node == nodeId }
    }

    func issueSeverity(for nodeId: String) -> String? {
        let nodeIssues = issues(for: nodeId)
        if nodeIssues.contains(where: \.isError) { return "error" }
        if nodeIssues.contains(where: \.isWarning) { return "warning" }
        return nil
    }

    func missingInputs(for nodeId: String) -> Set<UInt32> {
        Set(issues.compactMap { issue in
            issue.code == "missing_input" && issue.node == nodeId ? issue.input : nil
        })
    }

    static func analyze(_ document: GraphDocument) -> GraphDiagnostics {
        do {
            let text = try document.encodedString()
            return analyze(jsonText: text)
        } catch {
            return GraphDiagnostics(
                ok: false,
                summary: GraphDiagnosticSummary(errors: 1),
                issues: [
                    GraphDiagnosticIssue(severity: "error",
                                         code: "encode_failed",
                                         message: error.localizedDescription,
                                         node: nil,
                                         edge: nil,
                                         input: nil)
                ])
        }
    }

    static func analyze(jsonText: String) -> GraphDiagnostics {
        let text = readCxxLongString {
            theia.graph_diagnostics_json_text(jsonText, $0, $1)
        }
        guard let data = text.data(using: .utf8),
              let diagnostics = try? JSONDecoder().decode(GraphDiagnostics.self, from: data) else {
            return GraphDiagnostics(
                ok: false,
                summary: GraphDiagnosticSummary(errors: 1),
                issues: [
                    GraphDiagnosticIssue(severity: "error",
                                         code: "diagnostics_decode_failed",
                                         message: "Diagnostics response could not be decoded",
                                         node: nil,
                                         edge: nil,
                                         input: nil)
                ])
        }
        return diagnostics
    }
}
