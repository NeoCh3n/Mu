// Generates a synthetic SQLite database written with Swift-encoded JSON,
// for the TypeScript compatibility tests. All data is fictional.
// Run: swift gen-swift-db.swift <output-path>

import Foundation
import CryptoKit
import SQLite3

// --- muSHA256 + MuCoding (byte-identical to MuCore) ---
extension Data {
    var muSHA256: String {
        SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined()
    }
}

func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
}

func dateString(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
}

// --- Fixture types (Encodable structs matching the Mu record shapes) ---
struct TaskRecord: Encodable {
    var id: String
    var projectID: String?
    var title: String
    var objective: String
    var successCriteria: [String]
    var constraints: [String]
    var pendingSteps: [String]
    var repositoryPath: String
    var status: String
    var assignedAgentIdentityID: String?
    var createdAt: Date
    var updatedAt: Date
}

struct ProjectRecord: Encodable {
    var id: String
    var displayName: String
    var repositoryPath: String
    var ownerPrincipalID: String
    var status: String
    var createdAt: Date
    var updatedAt: Date
}

struct RuntimeEndpoint: Encodable {
    var id: String
    var runtimeTypeID: String
    var displayName: String
    var adapterVersion: String
    var runtimeVersion: String
    var location: String
    var provenance: String
    var permissionModel: String
    var capabilities: [String]
    var status: String
    var guaranteeNote: String
    var lastProbedAt: Date
    var instanceIdentity: InstanceIdentity?
}

struct InstanceIdentity: Encodable {
    var provider: String
    var surfaceKind: String
    var identityBasis: String
    var stableInstanceKey: String
    var instanceLabel: String
    var executablePath: String?
}

struct AgentIdentity: Encodable {
    var id: String
    var displayName: String
    var shortName: String
    var role: String
    var summary: String
    var accentHex: String
    var availability: String
    var capabilityTags: [String]
    var createdAt: Date
}

struct ChatEntry: Encodable {
    var id: String
    var taskID: String
    var targetEndpointID: String?
    var deliveryState: String?
    var authorKind: String
    var authorName: String
    var text: String
    var createdAt: Date
}

struct ProjectContextPack: Encodable {
    var id: String
    var projectID: String
    var taskID: String
    var workspaceID: String
    var objective: String
    var relevantFilePaths: [String]
    var permissions: [String]
    var constraints: [String]
    var acceptanceTests: [String]
    var baseRevision: String
    var contentSHA256: String
    var createdAt: Date
}

struct LedgerEvent: Encodable {
    var id: String
    var schemaVersion: String
    var taskID: String?
    var projectID: String?
    var type: String
    var summary: String
    var payload: [String: String]
    var occurredAt: Date
}

// --- Main ---
let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

guard CommandLine.arguments.count >= 2 else {
    print("usage: swift gen-swift-db.swift <output-path>")
    exit(1)
}
let outputPath = CommandLine.arguments[1]

var db: OpaquePointer?
guard sqlite3_open(outputPath, &db) == SQLITE_OK else {
    print("cannot open database")
    exit(1)
}

func exec(_ sql: String) {
    var errorMessage: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(db, sql, nil, nil, &errorMessage) == SQLITE_OK else {
        let message = errorMessage.map { String(cString: $0) } ?? "unknown"
        print("SQL error: \(message)")
        exit(1)
    }
}

// Core tables (abridged but structurally identical subset).
exec("""
CREATE TABLE IF NOT EXISTS records (
    kind TEXT NOT NULL, id TEXT NOT NULL, task_id TEXT,
    sort_at TEXT NOT NULL, json TEXT NOT NULL,
    PRIMARY KEY (kind, id)
);
CREATE INDEX IF NOT EXISTS records_kind_sort ON records(kind, sort_at DESC);
CREATE INDEX IF NOT EXISTS records_task ON records(task_id, kind, sort_at DESC);
CREATE TABLE IF NOT EXISTS ledger (
    sequence INTEGER PRIMARY KEY AUTOINCREMENT,
    event_id TEXT NOT NULL UNIQUE, task_id TEXT, run_id TEXT,
    type TEXT NOT NULL, occurred_at TEXT NOT NULL, json TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS maintenance (key TEXT PRIMARY KEY, value TEXT NOT NULL);
""")

// Fixed timestamps so the TS test can assert exact values.
let t1 = Date(timeIntervalSince1970: 1_752_433_665)        // 2025-07-13T19:07:45Z
let t2 = Date(timeIntervalSince1970: 1_752_433_700)        // +35s
let taskID = "d1d2d3d4-d5d6-d7d8-d9da-dbdcdddedfe0"
let projectID = "a1b2c3d4-e5f6-4789-abcd-ef0123456789"
let endpointID = "b2c3d4e5-f6a7-489b-8cde-f0123456789a"
let agentID = "c3d4e5f6-a7b8-49cd-8e01-23456789abcd"
let principalID = "e5f6a7b8-c9d0-4e1f-8a2b-3c4d5e6f7a8b"

let task = TaskRecord(
    id: taskID,
    projectID: projectID,
    title: "Implement widget",
    objective: "Build the widget renderer",
    successCriteria: ["tests pass", "widget renders"],
    constraints: ["No new dependencies"],
    pendingSteps: ["write tests", "implement"],
    repositoryPath: "/Users/synthetic/widgets",
    status: "ready",
    assignedAgentIdentityID: agentID,
    createdAt: t1,
    updatedAt: t2
)

let project = ProjectRecord(
    id: projectID,
    displayName: "Widgets",
    repositoryPath: "/Users/synthetic/widgets",
    ownerPrincipalID: principalID,
    status: "active",
    createdAt: t1,
    updatedAt: t2
)

let endpoint = RuntimeEndpoint(
    id: endpointID,
    runtimeTypeID: "openai.codex/app-server",
    displayName: "Codex App Server",
    adapterVersion: "0.1.0",
    runtimeVersion: "1.0.0",
    location: "local",
    provenance: "vendor_protocol",
    permissionModel: "fine_grained",
    capabilities: ["start", "replan", "stream_events", "cancel"],
    status: "active",
    guaranteeNote: "official",
    lastProbedAt: t2,
    instanceIdentity: InstanceIdentity(
        provider: "codex",
        surfaceKind: "desktop_application",
        identityBasis: "desktop_singleton",
        stableInstanceKey: "codex:desktop",
        instanceLabel: "Codex Desktop"
    )
)

let agent = AgentIdentity(
    id: agentID,
    displayName: "Atlas",
    shortName: "atlas",
    role: "builder",
    summary: "Builds widgets",
    accentHex: "#4f8cff",
    availability: "available",
    capabilityTags: ["swift", "typescript"],
    createdAt: t1
)

let chat1 = ChatEntry(
    id: "f6a7b8c9-d0e1-4f2a-8b3c-4d5e6f7a8b9c",
    taskID: taskID,
    targetEndpointID: endpointID,
    deliveryState: "delivered",
    authorKind: "user",
    authorName: "Synthetic User",
    text: "Please implement the widget",
    createdAt: t1
)

let chat2 = ChatEntry(
    id: "a7b8c9d0-e1f2-4a3b-8c4d-5e6f7a8b9c0d",
    taskID: taskID,
    targetEndpointID: endpointID,
    deliveryState: "delivered",
    authorKind: "agent",
    authorName: "Atlas",
    text: "I will implement the widget",
    createdAt: t2
)

let pack = ProjectContextPack(
    id: "b8c9d0e1-f2a3-4b4c-8d5e-6f7a8b9c0d1e",
    projectID: projectID,
    taskID: taskID,
    workspaceID: "c9d0e1f2-a3b4-4c5d-8e6f-7a8b9c0d1e2f",
    objective: "Implement the widget",
    relevantFilePaths: ["src/widget.ts"],
    permissions: ["project.read", "repository.read"],
    constraints: ["No new dependencies"],
    acceptanceTests: ["widget renders"],
    baseRevision: "abc1234",
    contentSHA256: "c".padding(toLength: 64, withPad: "0", startingAt: 0),
    createdAt: t2
)

let event = LedgerEvent(
    id: "d9e0f1a2-b3c4-4d5e-8f6a-7b8c9d0e1f2a",
    schemaVersion: "1.0",
    taskID: taskID,
    projectID: projectID,
    type: "task.created",
    summary: "Task created",
    payload: ["source": "synthetic"],
    occurredAt: t1
)

func insertRecord(kind: String, id: String, taskID: String?, sortAt: Date, value: some Encodable) {
    let data = try! makeEncoder().encode(value)
    let json = String(decoding: data, as: UTF8.self)
    var stmt: OpaquePointer?
    sqlite3_prepare_v2(db, "INSERT INTO records(kind, id, task_id, sort_at, json) VALUES (?, ?, ?, ?, ?);", -1, &stmt, nil)
    sqlite3_bind_text(stmt, 1, kind, -1, SQLITE_TRANSIENT)
    sqlite3_bind_text(stmt, 2, id, -1, SQLITE_TRANSIENT)
    if let taskID {
        sqlite3_bind_text(stmt, 3, taskID, -1, SQLITE_TRANSIENT)
    } else {
        sqlite3_bind_null(stmt, 3)
    }
    sqlite3_bind_text(stmt, 4, dateString(sortAt), -1, SQLITE_TRANSIENT)
    sqlite3_bind_text(stmt, 5, json, -1, SQLITE_TRANSIENT)
    guard sqlite3_step(stmt) == SQLITE_DONE else {
        print("insert failed for \(kind)")
        exit(1)
    }
    sqlite3_finalize(stmt)
}

insertRecord(kind: "task", id: taskID, taskID: taskID, sortAt: t2, value: task)
insertRecord(kind: "project", id: projectID, taskID: nil, sortAt: t2, value: project)
insertRecord(kind: "endpoint", id: endpointID, taskID: nil, sortAt: t2, value: endpoint)
insertRecord(kind: "agent_identity", id: agentID, taskID: nil, sortAt: t1, value: agent)
insertRecord(kind: "chat_entry", id: chat1.id, taskID: taskID, sortAt: t1, value: chat1)
insertRecord(kind: "chat_entry", id: chat2.id, taskID: taskID, sortAt: t2, value: chat2)
insertRecord(kind: "project_context_pack", id: pack.id, taskID: taskID, sortAt: t2, value: pack)

// Ledger event.
var stmt: OpaquePointer?
let eventJSON = String(decoding: try! makeEncoder().encode(event), as: UTF8.self)
sqlite3_prepare_v2(db, "INSERT INTO ledger(event_id, task_id, run_id, type, occurred_at, json) VALUES (?, ?, ?, ?, ?, ?);", -1, &stmt, nil)
sqlite3_bind_text(stmt, 1, event.id, -1, SQLITE_TRANSIENT)
sqlite3_bind_text(stmt, 2, event.taskID, -1, SQLITE_TRANSIENT)
sqlite3_bind_null(stmt, 3)
sqlite3_bind_text(stmt, 4, event.type, -1, SQLITE_TRANSIENT)
sqlite3_bind_text(stmt, 5, dateString(event.occurredAt), -1, SQLITE_TRANSIENT)
sqlite3_bind_text(stmt, 6, eventJSON, -1, SQLITE_TRANSIENT)
guard sqlite3_step(stmt) == SQLITE_DONE else {
    print("ledger insert failed")
    exit(1)
}
sqlite3_finalize(stmt)

sqlite3_close(db)
print("wrote \(outputPath)")
