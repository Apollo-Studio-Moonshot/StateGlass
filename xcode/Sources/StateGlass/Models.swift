import Foundation

struct Project: Decodable, Identifiable, Sendable {
    let id: String
    let name: String
    let rootPath: String
    let language: String
    var entryPoint: String?
    var runArgs: [String]
    var timeoutMs: UInt64
    var tracing: Bool
    var consentGranted: Bool
    var pythonPath: String?
}

struct ProjectConfigInput: Encodable, Sendable {
    let entryPoint: String?
    let runArgs: [String]
    let timeoutMs: UInt64
    let tracing: Bool
    let pythonPath: String?
}

struct FileEntry: Decodable, Identifiable, Sendable {
    let path: String
    let name: String
    let isDir: Bool
    let isPython: Bool
    let size: UInt64
    var id: String { path }
}

struct FileContent: Decodable, Sendable {
    let path: String
    let content: String
    let size: UInt64
    let language: String
    let modifiedAt: Int64
}

struct Session: Decodable, Identifiable, Sendable {
    let id: String
    let projectId: String
    let experimentId: String?
    let kind: String
    let label: String?
    let command: String
    let status: String
    let exitCode: Int32?
    let startedAt: Int64
    let finishedAt: Int64?
    let durationMs: Int64?
    let peakMemoryBytes: Int64?
    let traceEventCount: Int64
    let traceTruncated: Bool
    let error: String?
    let stdoutPreview: String
    let stderrPreview: String
}

struct RunRequest: Encodable, Sendable {
    let projectId: String
    let experimentId: String?
    let baselineSessionId: String?
    let stdin: String?
}

struct TraceEvent: Decodable, Identifiable, Sendable {
    let id: Int64
    let sessionId: String
    let seq: Int64
    let ts: Int64
    let kind: String
    let file: String?
    let line: Int64?
    let functionName: String?
    let name: String?
    let value: String?
    let changed: Bool?

    enum CodingKeys: String, CodingKey {
        case id, sessionId, seq, ts, kind, file, line, name, value, changed
        case functionName = "func"
    }
}

struct TracePage: Decodable, Sendable {
    let events: [TraceEvent]
    let total: Int64
    let returned: Int
}

struct VariableSnapshot: Decodable, Identifiable, Sendable {
    let name: String
    let value: String
    let vtype: String
    let file: String?
    let line: Int64?
    let funcName: String?
    let seq: Int64
    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, value, vtype, file, line, seq
        case funcName = "func"
    }
}

struct FlowNode: Decodable, Identifiable, Sendable {
    let id: String
    let label: String
    let value: String
    let vtype: String
    let file: String?
    let line: Int64?
    let funcName: String?
    let seq: Int64
    let step: Int64
    let role: String

    enum CodingKeys: String, CodingKey {
        case id, label, value, vtype, file, line, seq, step, role
        case funcName = "func"
    }
}

struct FlowAssignment: Decodable, Identifiable, Sendable {
    let file: String
    let line: Int64
    let funcName: String
    let target: String
    let sources: [String]
    let kind: String
    let matched: Bool
    var id: String { "\(file):\(line):\(target)" }

    enum CodingKeys: String, CodingKey {
        case file, line, target, sources, kind, matched
        case funcName = "func"
    }
}

struct DataFlow: Decodable, Sendable {
    let variable: String
    let nodes: [FlowNode]
    let edges: [FlowEdge]
    let assignmentSites: [FlowAssignment]
    let truncated: Bool
    let note: String
}

struct FlowEdge: Decodable, Identifiable, Sendable {
    let id: String
    let source: String
    let target: String
    let label: String
    let kind: String
}

struct Experiment: Decodable, Identifiable, Sendable {
    let id: String
    let name: String
    let note: String?
    let path: String
    let baselineSessionId: String
}

struct DiffLine: Decodable, Identifiable, Sendable {
    let kind: String
    let baselineLine: Int?
    let experimentLine: Int?
    let text: String
    var id: String { "\(kind):\(baselineLine ?? 0):\(experimentLine ?? 0):\(text)" }
}

struct VariableDiff: Decodable, Identifiable, Sendable {
    let name: String
    let baselineValue: String?
    let experimentValue: String?
    let status: String
    var id: String { name }
}

struct RunMetrics: Decodable, Sendable {
    let durationMs: Int64?
    let peakMemoryBytes: Int64?
    let exitCode: Int32?
    let status: String
}

struct SessionComparison: Decodable, Sendable {
    let baseline: Session
    let experiment: Session
    let baselineMetrics: RunMetrics
    let experimentMetrics: RunMetrics
    let stdout: [DiffLine]
    let stderr: [DiffLine]
    let variables: [VariableDiff]
    let stdoutDivergence: Int?
    let warnings: [String]
}

struct Bootstrap: Decodable, Sendable {
    let version: String
    let dataDir: String
    let platform: String
    let tracerAvailable: Bool
    let initialProjectPath: String?
}

struct SidecarEvent: Sendable {
    let name: String
    let payload: Data
}
