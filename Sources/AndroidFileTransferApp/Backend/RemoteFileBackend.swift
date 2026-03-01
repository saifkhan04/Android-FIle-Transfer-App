import Foundation

protocol RemoteFileBackend {
    var isAvailable: Bool { get }
    var unavailableReason: String? { get }

    func listDevices() async throws -> [ConnectedDevice]
    func listDirectory(serial: String, path: String) async throws -> DirectorySnapshot
    func listFilesRecursively(serial: String, path: String) async throws -> [String]
    func pullWithProgress(
        serial: String,
        remotePath: String,
        localDirectory: String,
        onProcessStarted: @escaping (Process) -> Void,
        onProgress: @escaping (Double) -> Void
    ) async throws
    func pushWithProgress(
        serial: String,
        localPath: String,
        remoteDirectory: String,
        onProcessStarted: @escaping (Process) -> Void,
        onProgress: @escaping (Double) -> Void
    ) async throws
    func deleteRemote(serial: String, path: String) async throws
}
