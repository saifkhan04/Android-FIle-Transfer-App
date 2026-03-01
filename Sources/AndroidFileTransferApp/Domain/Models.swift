import Foundation

struct RemoteEntry: Identifiable, Hashable {
    let name: String
    let fullPath: String
    let isDirectory: Bool

    var id: String { fullPath }
}

struct LocalEntry: Identifiable, Hashable {
    let name: String
    let fullPath: String
    let isDirectory: Bool

    var id: String { fullPath }
}

enum TransferDirection: String {
    case upload = "Upload"
    case download = "Download"
}

enum TransferTaskState: Equatable {
    case pending
    case inProgress
    case completed
    case cancelled
    case failed(String)

    var label: String {
        switch self {
        case .pending: return "Pending"
        case .inProgress: return "Transferring"
        case .completed: return "Completed"
        case .cancelled: return "Cancelled"
        case .failed: return "Failed"
        }
    }
}

struct TransferTask: Identifiable {
    let id: UUID
    let name: String
    let direction: TransferDirection
    var progress: Double
    var state: TransferTaskState
}

struct DirectorySnapshot {
    let requestedPath: String
    let resolvedPath: String
    let entries: [RemoteEntry]
    let rawListOutput: String
}

struct ConnectedDevice: Hashable {
    let id: String
    let displayName: String
}

enum BackendError: LocalizedError {
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let message):
            return message
        }
    }
}
