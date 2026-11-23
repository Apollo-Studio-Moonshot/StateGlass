import Foundation

enum ContextNodeKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case frontend
    case billing
    case marketing
    case database

    var id: String { rawValue }

    var title: String {
        switch self {
        case .frontend: "Frontend"
        case .billing: "Billing"
        case .marketing: "Marketing"
        case .database: "Database"
        }
    }

    var symbol: String {
        switch self {
        case .frontend: "window"
        case .billing: "card"
        case .marketing: "megaphone"
        case .database: "database"
        }
    }
}

enum ContextNodeStatus: String, Codable, Sendable {
    case draft
    case active
    case needsReview

    var title: String {
        switch self {
        case .draft: "Draft"
        case .active: "Active"
        case .needsReview: "Needs review"
        }
    }
}

struct ContextNode: Codable, Identifiable, Sendable {
    let id: String
    let kind: ContextNodeKind
    var title: String
    var summary: String
    var status: ContextNodeStatus
    var x: Double
    var y: Double
}

struct NodeDependency: Codable, Identifiable, Sendable {
    let id: String
    let sourceId: String
    let targetId: String
}

struct CanvasSnapshot: Codable, Sendable {
    let nodes: [ContextNode]
    let dependencies: [NodeDependency]
}

enum CanvasMode: String, CaseIterable, Identifiable {
    case build
    case triage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .build: "Build"
        case .triage: "Triage"
        }
    }
}
