import SwiftUI
import Foundation
import AppKit

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

@MainActor
final class AppViewModel: ObservableObject {
    @Published var adbPath: String = ""
    @Published var deviceSerial: String = ""
    @Published var deviceDisplayName: String = "None"
    @Published var remoteCurrentPath: String = "/sdcard"
    @Published var remoteEntries: [RemoteEntry] = []
    @Published var selectedRemoteEntryIDs: Set<String> = []
    @Published var localCurrentPath: String = (FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path ?? NSHomeDirectory())
    @Published var localEntries: [LocalEntry] = []
    @Published var selectedLocalEntryIDs: Set<String> = []
    @Published var status: String = "Ready"
    @Published var isBusy: Bool = false
    @Published var debugInfo: String = ""
    @Published var remoteListRevision: Int = 0
    @Published var localListRevision: Int = 0
    @Published var transferPercent: Double? = nil
    @Published var transferETASeconds: TimeInterval? = nil
    @Published var transferLabel: String = ""
    @Published var transferTasks: [TransferTask] = []

    private var activeProcess: Process?
    private var transferCancelledByUser: Bool = false
    private var remoteHistory: [String] = []
    private var remoteHistoryIndex: Int = -1
    private var localHistory: [String] = []
    private var localHistoryIndex: Int = -1

    var selectedRemoteEntries: [RemoteEntry] { remoteEntries.filter { selectedRemoteEntryIDs.contains($0.id) } }
    var selectedLocalEntries: [LocalEntry] { localEntries.filter { selectedLocalEntryIDs.contains($0.id) } }

    var canRemoteBack: Bool { remoteHistoryIndex > 0 && remoteCurrentPath != "/" }
    var canRemoteForward: Bool { remoteHistoryIndex >= 0 && remoteHistoryIndex < remoteHistory.count - 1 }
    var canLocalBack: Bool { localHistoryIndex > 0 && localCurrentPath != "/" }
    var canLocalForward: Bool { localHistoryIndex >= 0 && localHistoryIndex < localHistory.count - 1 }
    var hasTransferQueue: Bool { !transferTasks.isEmpty }
    var isAllRemoteSelected: Bool { !remoteEntries.isEmpty && selectedRemoteEntryIDs.count == remoteEntries.count }
    var isAllLocalSelected: Bool { !localEntries.isEmpty && selectedLocalEntryIDs.count == localEntries.count }

    func initialize() async {
        do {
            try refreshLocalDirectory()
            initializeLocalHistoryIfNeeded()
        } catch {
            status = "Failed to load local files: \(error.localizedDescription)"
        }

        adbPath = ADBService.findADB() ?? ""

        guard !adbPath.isEmpty else {
            status = "adb not found. Install Android Platform Tools and ensure adb is in PATH."
            return
        }

        await refreshDevicesAndFiles()
    }

    func refreshDevicesAndFiles() async {
        guard !adbPath.isEmpty else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            let devices = try await ADBService.listDevices(adbPath: adbPath)
            guard let first = devices.first else {
                deviceSerial = ""
                deviceDisplayName = "None"
                remoteEntries = []
                selectedRemoteEntryIDs = []
                status = "No Android device detected. Connect phone and enable USB debugging."
                return
            }

            deviceSerial = first
            if let friendly = try? await ADBService.friendlyDeviceName(adbPath: adbPath, serial: deviceSerial) {
                deviceDisplayName = friendly
            } else {
                deviceDisplayName = deviceSerial
            }
            status = "Connected to \(deviceDisplayName)."
            let snapshot = try await ADBService.listDirectory(adbPath: adbPath, serial: deviceSerial, path: remoteCurrentPath)
            apply(snapshot: snapshot)
        } catch {
            status = "Failed to refresh: \(error.localizedDescription)"
        }
    }

    func refreshAllPanes() async {
        do {
            try refreshLocalDirectory()
        } catch {
            status = "Failed to refresh local files: \(error.localizedDescription)"
        }
        await refreshDevicesAndFiles()
    }

    func openRemoteDirectory(_ entry: RemoteEntry) async {
        guard entry.isDirectory else {
            status = "\(entry.name) is not a folder."
            return
        }
        recordRemoteHistory(entry.fullPath)
        remoteCurrentPath = entry.fullPath
        await refreshRemoteDirectory()
    }

    func openLocalDirectory(_ entry: LocalEntry) {
        guard entry.isDirectory else {
            status = "\(entry.name) is not a folder."
            return
        }
        recordLocalHistory(entry.fullPath)
        localCurrentPath = entry.fullPath
        do {
            try refreshLocalDirectory()
        } catch {
            status = "Failed to list \(localCurrentPath): \(error.localizedDescription)"
        }
    }

    func openSelectedRemote() async {
        guard let selected = selectedRemoteEntries.first else {
            status = "Select a remote folder to open."
            return
        }
        await openRemoteDirectory(selected)
    }

    func openSelectedLocal() {
        guard let selected = selectedLocalEntries.first else {
            status = "Select a local folder to open."
            return
        }
        openLocalDirectory(selected)
    }

    func remoteUp() async {
        guard remoteCurrentPath != "/" else { return }
        let parent = (remoteCurrentPath as NSString).deletingLastPathComponent
        remoteCurrentPath = parent.isEmpty ? "/" : parent
        recordRemoteHistory(remoteCurrentPath)
        await refreshRemoteDirectory()
    }

    func localUp() {
        guard localCurrentPath != "/" else { return }
        let parent = (localCurrentPath as NSString).deletingLastPathComponent
        localCurrentPath = parent.isEmpty ? "/" : parent
        recordLocalHistory(localCurrentPath)
        do {
            try refreshLocalDirectory()
        } catch {
            status = "Failed to list \(localCurrentPath): \(error.localizedDescription)"
        }
    }

    func remoteBack() async {
        guard canRemoteBack, remoteCurrentPath != "/" else { return }
        remoteHistoryIndex -= 1
        remoteCurrentPath = remoteHistory[remoteHistoryIndex]
        await refreshRemoteDirectory()
    }

    func remoteForward() async {
        guard canRemoteForward else { return }
        remoteHistoryIndex += 1
        remoteCurrentPath = remoteHistory[remoteHistoryIndex]
        await refreshRemoteDirectory()
    }

    func localBack() {
        guard canLocalBack, localCurrentPath != "/" else { return }
        localHistoryIndex -= 1
        localCurrentPath = localHistory[localHistoryIndex]
        do {
            try refreshLocalDirectory()
        } catch {
            status = "Failed to list \(localCurrentPath): \(error.localizedDescription)"
        }
    }

    func localForward() {
        guard canLocalForward else { return }
        localHistoryIndex += 1
        localCurrentPath = localHistory[localHistoryIndex]
        do {
            try refreshLocalDirectory()
        } catch {
            status = "Failed to list \(localCurrentPath): \(error.localizedDescription)"
        }
    }

    func refreshRemoteDirectory() async {
        guard !deviceSerial.isEmpty, !adbPath.isEmpty else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            let snapshot = try await ADBService.listDirectory(adbPath: adbPath, serial: deviceSerial, path: remoteCurrentPath)
            apply(snapshot: snapshot)
            status = "Loaded \(remoteEntries.count) items from \(remoteCurrentPath)."
        } catch {
            status = "Failed to list \(remoteCurrentPath): \(error.localizedDescription)"
        }
    }

    func refreshLocalDirectory() throws {
        let listed = try Self.listLocalDirectory(path: localCurrentPath)
        localEntries = listed
        selectedLocalEntryIDs = []
        localListRevision += 1
    }

    func uploadSelectedLocalToRemote() async {
        guard !deviceSerial.isEmpty else {
            status = "No Android device connected."
            return
        }
        let selected = selectedLocalEntries
        guard !selected.isEmpty else {
            status = "Select one or more local files/folders first."
            return
        }
        guard !remoteCurrentPath.isEmpty else {
            status = "Remote folder is not available."
            return
        }
        await uploadLocalEntries(selected)
    }

    func downloadSelectedRemoteToLocal() async {
        guard !deviceSerial.isEmpty else {
            status = "No Android device connected."
            return
        }
        let selected = selectedRemoteEntries
        guard !selected.isEmpty else {
            status = "Select one or more remote files/folders first."
            return
        }
        await downloadRemoteEntries(selected, toDirectory: localCurrentPath)
    }

    func cancelAllTransfers() {
        guard isBusy || hasTransferQueue else { return }
        transferCancelledByUser = true
        cancelAllPendingTasks()
        if let index = transferTasks.firstIndex(where: { $0.state == .inProgress }) {
            transferTasks[index].state = .cancelled
        }
        activeProcess?.terminate()
    }

    func clearQueue() {
        guard !isBusy else {
            status = "Stop active transfers before clearing the queue."
            return
        }
        transferTasks.removeAll()
        if !deviceSerial.isEmpty {
            status = "Connected to \(deviceDisplayName)."
        } else {
            status = "Ready"
        }
    }

    func deleteSelectedRemote() async {
        guard !deviceSerial.isEmpty else {
            status = "No Android device connected."
            return
        }
        let selected = selectedRemoteEntries
        guard !selected.isEmpty else {
            status = "Select one or more remote items to delete."
            return
        }

        isBusy = true
        defer { isBusy = false }

        do {
            for entry in selected {
                try await ADBService.deleteRemote(adbPath: adbPath, serial: deviceSerial, path: entry.fullPath)
            }
            status = "Deleted \(selected.count) remote item(s)."
            let snapshot = try await ADBService.listDirectory(adbPath: adbPath, serial: deviceSerial, path: remoteCurrentPath)
            apply(snapshot: snapshot)
        } catch {
            status = "Remote delete failed: \(error.localizedDescription)"
        }
    }

    func deleteSelectedLocal() {
        let selected = selectedLocalEntries
        guard !selected.isEmpty else {
            status = "Select one or more local items to delete."
            return
        }

        do {
            for entry in selected {
                try FileManager.default.removeItem(atPath: entry.fullPath)
            }
            status = "Deleted \(selected.count) local item(s)."
            try refreshLocalDirectory()
        } catch {
            status = "Local delete failed: \(error.localizedDescription)"
        }
    }

    func cancelPendingTransfer(id: UUID) {
        guard let index = transferTasks.firstIndex(where: { $0.id == id }) else { return }
        if transferTasks[index].state == .pending {
            transferTasks[index].state = .cancelled
            transferTasks[index].progress = 0
        }
    }

    private func uploadLocalEntries(_ entries: [LocalEntry]) async {
        isBusy = true
        transferCancelledByUser = false
        resetProgress()
        setupTransferQueue(names: entries.map(\.name), direction: .upload)
        defer { isBusy = false }

        do {
            for (index, entry) in entries.enumerated() {
                guard let taskID = transferTasks[safe: index]?.id else { continue }
                if transferTasks[safe: index]?.state == .cancelled {
                    continue
                }
                setTaskState(id: taskID, state: .inProgress)
                transferLabel = "Uploading \(entry.name) (\(index + 1)/\(entries.count))"
                let start = Date()
                try await ADBService.pushWithProgress(
                    adbPath: adbPath,
                    serial: deviceSerial,
                    localPath: entry.fullPath,
                    remoteDirectory: remoteCurrentPath,
                    onProcessStarted: { [weak self] process in
                        Task { @MainActor in
                            self?.activeProcess = process
                        }
                    },
                    onProgress: { [weak self] percent in
                        Task { @MainActor in
                            guard let self else { return }
                            self.updateProgress(percent: percent, start: start, index: index, total: entries.count)
                            self.updateTaskProgress(id: taskID, percent: percent)
                        }
                    }
                )
                setTaskProgress(id: taskID, value: 100)
                setTaskState(id: taskID, state: .completed)
            }
            status = "Uploaded \(entries.count) item(s) to \(remoteCurrentPath)."
            let snapshot = try await ADBService.listDirectory(adbPath: adbPath, serial: deviceSerial, path: remoteCurrentPath)
            apply(snapshot: snapshot)
        } catch {
            markInProgressTaskAsFailedOrCancelled()
            if transferCancelledByUser {
                cancelAllPendingTasks()
            }
            status = transferCancelledByUser ? "Upload cancelled." : "Upload failed: \(error.localizedDescription)"
        }
        resetProgress()
        activeProcess = nil
    }

    private func updateProgress(percent: Double, start: Date, index: Int, total: Int) {
        let bounded = min(max(percent, 0), 100)
        let overall = ((Double(index) + bounded / 100.0) / Double(max(total, 1))) * 100.0
        transferPercent = overall

        if bounded > 0.1 {
            let elapsed = Date().timeIntervalSince(start)
            let eta = elapsed * ((100.0 / bounded) - 1.0)
            transferETASeconds = max(0, eta)
        } else {
            transferETASeconds = nil
        }
    }

    private func resetProgress() {
        transferPercent = nil
        transferETASeconds = nil
        transferLabel = ""
    }

    var formattedETA: String {
        guard let eta = transferETASeconds, eta.isFinite else { return "" }
        let total = Int(eta.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }

    var transferPercentText: String {
        guard let transferPercent else { return "" }
        return String(format: "%.0f%%", transferPercent)
    }

    private func downloadRemoteEntries(_ entries: [RemoteEntry], toDirectory destination: String) async {
        struct DownloadJob {
            let displayName: String
            let remotePath: String
            let localDirectory: String
        }

        isBusy = true
        transferCancelledByUser = false
        resetProgress()
        defer { isBusy = false }

        do {
            var jobs: [DownloadJob] = []
            let fm = FileManager.default

            for entry in entries {
                if entry.isDirectory {
                    let files = try await ADBService.listFilesRecursively(adbPath: adbPath, serial: deviceSerial, path: entry.fullPath)

                    // Preserve folder structure under the selected local destination.
                    let baseOutputDir = (destination as NSString).appendingPathComponent(entry.name)
                    try fm.createDirectory(atPath: baseOutputDir, withIntermediateDirectories: true)

                    for file in files {
                        let relative = Self.relativeRemotePath(file, fromBase: entry.fullPath)
                        let parentRelative = (relative as NSString).deletingLastPathComponent
                        let targetDir = parentRelative.isEmpty
                            ? baseOutputDir
                            : (baseOutputDir as NSString).appendingPathComponent(parentRelative)
                        try fm.createDirectory(atPath: targetDir, withIntermediateDirectories: true)

                        let display = "\(entry.name)/\(relative)"
                        jobs.append(DownloadJob(displayName: display, remotePath: file, localDirectory: targetDir))
                    }
                } else {
                    jobs.append(DownloadJob(displayName: entry.name, remotePath: entry.fullPath, localDirectory: destination))
                }
            }

            if jobs.isEmpty {
                status = "No files found to download."
                return
            }

            setupTransferQueue(names: jobs.map(\.displayName), direction: .download)

            for (index, job) in jobs.enumerated() {
                guard let taskID = transferTasks[safe: index]?.id else { continue }
                if transferTasks[safe: index]?.state == .cancelled {
                    continue
                }
                setTaskState(id: taskID, state: .inProgress)
                transferLabel = "Downloading \(job.displayName) (\(index + 1)/\(jobs.count))"
                let start = Date()
                try await ADBService.pullWithProgress(
                    adbPath: adbPath,
                    serial: deviceSerial,
                    remotePath: job.remotePath,
                    localDirectory: job.localDirectory,
                    onProcessStarted: { [weak self] process in
                        Task { @MainActor in
                            self?.activeProcess = process
                        }
                    },
                    onProgress: { [weak self] percent in
                        Task { @MainActor in
                            guard let self else { return }
                            self.updateProgress(percent: percent, start: start, index: index, total: jobs.count)
                            self.updateTaskProgress(id: taskID, percent: percent)
                        }
                    }
                )
                setTaskProgress(id: taskID, value: 100)
                setTaskState(id: taskID, state: .completed)
            }
            status = "Downloaded \(jobs.count) file(s) to \(destination)."
            try refreshLocalDirectory()
        } catch {
            markInProgressTaskAsFailedOrCancelled()
            if transferCancelledByUser {
                cancelAllPendingTasks()
            }
            status = transferCancelledByUser ? "Download cancelled." : "Download failed: \(error.localizedDescription)"
        }
        resetProgress()
        activeProcess = nil
    }

    private static func relativeRemotePath(_ path: String, fromBase base: String) -> String {
        let normalizedBase = base.hasSuffix("/") ? String(base.dropLast()) : base
        if path == normalizedBase {
            return (path as NSString).lastPathComponent
        }
        let prefix = normalizedBase + "/"
        if path.hasPrefix(prefix) {
            return String(path.dropFirst(prefix.count))
        }
        return (path as NSString).lastPathComponent
    }

    private func apply(snapshot: DirectorySnapshot) {
        remoteEntries = snapshot.entries
        remoteCurrentPath = snapshot.resolvedPath
        syncRemoteHistoryCurrentPath(snapshot.resolvedPath)
        selectedRemoteEntryIDs = []
        remoteListRevision += 1
        debugInfo = """
        Requested: \(snapshot.requestedPath)
        Resolved: \(snapshot.resolvedPath)
        Items: \(snapshot.entries.count)
        Raw:
        \(snapshot.rawListOutput)
        """
    }

    private func initializeLocalHistoryIfNeeded() {
        guard localHistory.isEmpty else { return }
        localHistory = [localCurrentPath]
        localHistoryIndex = 0
    }

    private func recordRemoteHistory(_ path: String) {
        if remoteHistory.isEmpty {
            remoteHistory = [path]
            remoteHistoryIndex = 0
            return
        }

        if remoteHistoryIndex >= 0 && remoteHistoryIndex < remoteHistory.count && remoteHistory[remoteHistoryIndex] == path {
            return
        }

        if remoteHistoryIndex < remoteHistory.count - 1 {
            remoteHistory.removeSubrange((remoteHistoryIndex + 1)..<remoteHistory.count)
        }
        remoteHistory.append(path)
        remoteHistoryIndex = remoteHistory.count - 1
    }

    private func recordLocalHistory(_ path: String) {
        if localHistory.isEmpty {
            localHistory = [path]
            localHistoryIndex = 0
            return
        }

        if localHistoryIndex >= 0 && localHistoryIndex < localHistory.count && localHistory[localHistoryIndex] == path {
            return
        }

        if localHistoryIndex < localHistory.count - 1 {
            localHistory.removeSubrange((localHistoryIndex + 1)..<localHistory.count)
        }
        localHistory.append(path)
        localHistoryIndex = localHistory.count - 1
    }

    private func syncRemoteHistoryCurrentPath(_ resolvedPath: String) {
        if remoteHistory.isEmpty {
            remoteHistory = [resolvedPath]
            remoteHistoryIndex = 0
            return
        }

        guard remoteHistoryIndex >= 0 && remoteHistoryIndex < remoteHistory.count else {
            remoteHistory = [resolvedPath]
            remoteHistoryIndex = 0
            return
        }

        remoteHistory[remoteHistoryIndex] = resolvedPath
    }

    private static func listLocalDirectory(path: String) throws -> [LocalEntry] {
        let fm = FileManager.default
        let names = try fm.contentsOfDirectory(atPath: path)
        var entries: [LocalEntry] = []
        entries.reserveCapacity(names.count)

        for name in names where name != "." && name != ".." {
            let fullPath = (path as NSString).appendingPathComponent(name)
            let values = try? URL(fileURLWithPath: fullPath).resourceValues(forKeys: [.isDirectoryKey])
            let isDirectory = values?.isDirectory == true
            entries.append(LocalEntry(name: name, fullPath: fullPath, isDirectory: isDirectory))
        }

        entries.sort {
            if $0.isDirectory != $1.isDirectory {
                return $0.isDirectory && !$1.isDirectory
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        return entries
    }

    func handleRemoteRowSelection(id: String, commandPressed: Bool) {
        if !selectedLocalEntryIDs.isEmpty {
            selectedLocalEntryIDs.removeAll()
        }
        if commandPressed {
            if selectedRemoteEntryIDs.contains(id) {
                selectedRemoteEntryIDs.remove(id)
            } else {
                selectedRemoteEntryIDs.insert(id)
            }
        } else {
            selectedRemoteEntryIDs = [id]
        }
    }

    func toggleRemoteSelection(id: String) {
        if !selectedLocalEntryIDs.isEmpty {
            selectedLocalEntryIDs.removeAll()
        }
        if selectedRemoteEntryIDs.contains(id) {
            selectedRemoteEntryIDs.remove(id)
        } else {
            selectedRemoteEntryIDs.insert(id)
        }
    }

    func toggleSelectAllRemote() {
        if !selectedLocalEntryIDs.isEmpty {
            selectedLocalEntryIDs.removeAll()
        }
        if isAllRemoteSelected {
            selectedRemoteEntryIDs.removeAll()
        } else {
            selectedRemoteEntryIDs = Set(remoteEntries.map(\.id))
        }
    }

    func handleLocalRowSelection(id: String, commandPressed: Bool) {
        if !selectedRemoteEntryIDs.isEmpty {
            selectedRemoteEntryIDs.removeAll()
        }
        if commandPressed {
            if selectedLocalEntryIDs.contains(id) {
                selectedLocalEntryIDs.remove(id)
            } else {
                selectedLocalEntryIDs.insert(id)
            }
        } else {
            selectedLocalEntryIDs = [id]
        }
    }

    func toggleLocalSelection(id: String) {
        if !selectedRemoteEntryIDs.isEmpty {
            selectedRemoteEntryIDs.removeAll()
        }
        if selectedLocalEntryIDs.contains(id) {
            selectedLocalEntryIDs.remove(id)
        } else {
            selectedLocalEntryIDs.insert(id)
        }
    }

    func toggleSelectAllLocal() {
        if !selectedRemoteEntryIDs.isEmpty {
            selectedRemoteEntryIDs.removeAll()
        }
        if isAllLocalSelected {
            selectedLocalEntryIDs.removeAll()
        } else {
            selectedLocalEntryIDs = Set(localEntries.map(\.id))
        }
    }

    private func setupTransferQueue(names: [String], direction: TransferDirection) {
        transferTasks = names.map {
            TransferTask(id: UUID(), name: $0, direction: direction, progress: 0, state: .pending)
        }
    }

    private func setTaskState(id: UUID, state: TransferTaskState) {
        guard let index = transferTasks.firstIndex(where: { $0.id == id }) else { return }
        transferTasks[index].state = state
    }

    private func setTaskProgress(id: UUID, value: Double) {
        guard let index = transferTasks.firstIndex(where: { $0.id == id }) else { return }
        transferTasks[index].progress = min(max(value, 0), 100)
    }

    private func updateTaskProgress(id: UUID, percent: Double) {
        // Keep this as metadata only; in-progress UI is intentionally indeterminate.
        setTaskProgress(id: id, value: percent)
    }

    private func markInProgressTaskAsFailedOrCancelled() {
        guard let index = transferTasks.firstIndex(where: { $0.state == .inProgress }) else { return }
        transferTasks[index].state = transferCancelledByUser ? .cancelled : .failed("Transfer failed")
    }

    private func cancelAllPendingTasks() {
        for index in transferTasks.indices where transferTasks[index].state == .pending {
            transferTasks[index].state = .cancelled
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

enum ADBError: LocalizedError {
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let message):
            return message
        }
    }
}

enum ADBService {
    private final class ThreadSafeBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var text: String = ""

        func append(_ chunk: String) {
            lock.lock()
            text += chunk
            lock.unlock()
        }

        func snapshot() -> String {
            lock.lock()
            let value = text
            lock.unlock()
            return value
        }
    }

    static func findADB() -> String? {
        let candidates = [
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            "/usr/bin/adb"
        ]

        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }

        let envPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for path in envPath.split(separator: ":") {
            let adb = String(path) + "/adb"
            if FileManager.default.isExecutableFile(atPath: adb) {
                return adb
            }
        }

        return nil
    }

    static func listDevices(adbPath: String) async throws -> [String] {
        let output = try await run(adbPath, ["devices"])
        let lines = output.split(separator: "\n").map(String.init)

        return lines.compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("List of devices") else { return nil }
            let parts = trimmed.split(separator: "\t")
            guard parts.count == 2, parts[1] == "device" else { return nil }
            return String(parts[0])
        }
    }

    static func friendlyDeviceName(adbPath: String, serial: String) async throws -> String {
        let manufacturer = try await readProp(adbPath: adbPath, serial: serial, key: "ro.product.manufacturer")
        let model = try await readProp(adbPath: adbPath, serial: serial, key: "ro.product.model")
        let deviceName = try await readProp(adbPath: adbPath, serial: serial, key: "ro.product.device")

        let cleanManufacturer = manufacturer.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanDevice = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)

        if !cleanManufacturer.isEmpty && !cleanModel.isEmpty {
            if cleanModel.lowercased().hasPrefix(cleanManufacturer.lowercased()) {
                return cleanModel
            }
            return "\(cleanManufacturer) \(cleanModel)"
        }
        if !cleanModel.isEmpty { return cleanModel }
        if !cleanDevice.isEmpty { return cleanDevice }
        return serial
    }

    static func listDirectory(adbPath: String, serial: String, path: String) async throws -> DirectorySnapshot {
        let resolvedPath = normalizePath(path)
        let output = try await run(adbPath, ["-s", serial, "shell", "ls", "-1Ap", shellEscapeForShell(resolvedPath)])
        let names = output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }

        var entries: [RemoteEntry] = []
        entries.reserveCapacity(names.count)

        for rawName in names {
            let isDirectory = rawName.hasSuffix("/")
            let name = isDirectory ? String(rawName.dropLast()) : rawName
            if name.isEmpty { continue }
            let fullPath = joinRemotePath(parent: resolvedPath, child: name)
            entries.append(RemoteEntry(name: name, fullPath: fullPath, isDirectory: isDirectory))
       }

        entries.sort {
            if $0.isDirectory != $1.isDirectory {
                return $0.isDirectory && !$1.isDirectory
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        let rawOutput = output.count > 4000 ? String(output.prefix(4000)) + "\n...[truncated]" : output
        return DirectorySnapshot(requestedPath: path, resolvedPath: resolvedPath, entries: entries, rawListOutput: rawOutput)
    }

    static func listFilesRecursively(adbPath: String, serial: String, path: String) async throws -> [String] {
        let output = try await run(adbPath, ["-s", serial, "shell", "find", shellEscapeForShell(path), "-type", "f"])
        return output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.hasPrefix("/") }
            .sorted()
    }

    static func pullWithProgress(
        adbPath: String,
        serial: String,
        remotePath: String,
        localDirectory: String,
        onProcessStarted: @escaping (Process) -> Void,
        onProgress: @escaping (Double) -> Void
    ) async throws {
        _ = try await runWithProgress(
            executable: adbPath,
            args: ["-s", serial, "pull", "-p", remotePath, localDirectory],
            onProcessStarted: onProcessStarted,
            onProgress: onProgress
        )
    }

    static func deleteRemote(adbPath: String, serial: String, path: String) async throws {
        _ = try await run(adbPath, ["-s", serial, "shell", "rm", "-rf", "--", shellEscapeForShell(path)])
    }

    static func pushWithProgress(
        adbPath: String,
        serial: String,
        localPath: String,
        remoteDirectory: String,
        onProcessStarted: @escaping (Process) -> Void,
        onProgress: @escaping (Double) -> Void
    ) async throws {
        _ = try await runWithProgress(
            executable: adbPath,
            args: ["-s", serial, "push", "-p", localPath, remoteDirectory],
            onProcessStarted: onProcessStarted,
            onProgress: onProgress
        )
    }

    private static func joinRemotePath(parent: String, child: String) -> String {
        let normalizedParent = parent == "/" ? "" : parent.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if parent == "/" {
            return "/\(child)"
        }
        return "/\(normalizedParent)/\(child)"
    }

    private static func normalizePath(_ path: String) -> String {
        var p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.isEmpty { p = "/sdcard" }
        if !p.hasPrefix("/") { p = "/" + p }
        while p.count > 1 && p.hasSuffix("/") {
            p.removeLast()
        }
        return p
    }

    private static func readProp(adbPath: String, serial: String, key: String) async throws -> String {
        let value = try await run(adbPath, ["-s", serial, "shell", "getprop", key])
        return value.replacingOccurrences(of: "\r", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // adb shell still invokes remote shell parsing; quote paths so characters like () are safe.
    private static func shellEscapeForShell(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private static func run(_ executable: String, _ args: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = args

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            process.terminationHandler = { proc in
                let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                let errData = stderr.fileHandleForReading.readDataToEndOfFile()

                let out = String(data: outData, encoding: .utf8) ?? ""
                let err = String(data: errData, encoding: .utf8) ?? ""

                if proc.terminationStatus == 0 {
                    continuation.resume(returning: out)
                } else {
                    let message = err.isEmpty ? out : err
                    continuation.resume(throwing: ADBError.commandFailed(message.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private static func runWithProgress(
        executable: String,
        args: [String],
        onProcessStarted: @escaping (Process) -> Void,
        onProgress: @escaping (Double) -> Void
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = args

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            let buffer = ThreadSafeBuffer()

            let handler: @Sendable (FileHandle) -> Void = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
                buffer.append(chunk)
                if let percent = extractPercent(from: chunk) {
                    onProgress(percent)
                }
            }

            stdout.fileHandleForReading.readabilityHandler = handler
            stderr.fileHandleForReading.readabilityHandler = handler

            process.terminationHandler = { proc in
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil

                let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                let out = String(data: outData, encoding: .utf8) ?? ""
                let err = String(data: errData, encoding: .utf8) ?? ""

                buffer.append(out + err)
                let finalOutput = buffer.snapshot()

                if proc.terminationStatus == 0 {
                    continuation.resume(returning: finalOutput)
                } else {
                    let message = finalOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: ADBError.commandFailed(message.isEmpty ? "adb transfer failed" : message))
                }
            }

            do {
                try process.run()
                onProcessStarted(process)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private static func extractPercent(from text: String) -> Double? {
        let pattern = #"([0-9]{1,3})%"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: range)
        guard let last = matches.last, last.numberOfRanges > 1,
              let percentRange = Range(last.range(at: 1), in: text),
              let percent = Double(text[percentRange]) else {
            return nil
        }
        return min(max(percent, 0), 100)
    }
}

struct FancyProgressBar: View {
    let progress: Double

    var clamped: Double {
        min(max(progress, 0), 100)
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let fillWidth = width * CGFloat(clamped / 100.0)

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.black.opacity(0.06),
                                Color.black.opacity(0.02)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                RoundedRectangle(cornerRadius: 10)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.blue,
                                Color.cyan
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(8, fillWidth))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.white.opacity(0.35), lineWidth: 1)
                    )
                    .animation(.easeOut(duration: 0.2), value: clamped)
            }
        }
        .frame(height: 16)
    }
}

struct IndeterminateProgressBar: View {
    @State private var animate = false

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let segmentWidth = max(28, width * 0.28)

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(
                        LinearGradient(
                            colors: [Color.black.opacity(0.06), Color.black.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                RoundedRectangle(cornerRadius: 10)
                    .fill(
                        LinearGradient(
                            colors: [Color.blue.opacity(0.9), Color.cyan.opacity(0.9)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: segmentWidth)
                    .offset(x: animate ? width - segmentWidth : 0)
                    .animation(.linear(duration: 0.9).repeatForever(autoreverses: true), value: animate)
            }
        }
        .frame(height: 16)
        .onAppear {
            animate = true
        }
    }
}

struct ContentView: View {
    @StateObject private var vm = AppViewModel()
    @State private var hoveredRemoteEntryID: String? = nil
    @State private var hoveredLocalEntryID: String? = nil
    @State private var footerHeight: CGFloat = 200
    @State private var footerDragStartHeight: CGFloat? = nil
    @State private var pendingDeleteTarget: DeleteTarget?

    private enum DeleteTarget {
        case remote
        case local
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Spacer()

                Text("Device: \(vm.deviceDisplayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)

            Divider()

            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Button {
                            vm.toggleSelectAllRemote()
                        } label: {
                            Image(systemName: vm.isAllRemoteSelected ? "checkmark.square.fill" : "square")
                                .foregroundStyle(vm.isAllRemoteSelected ? Color.accentColor : Color.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Select/Deselect all in Android pane")
                        Text("Android")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(vm.remoteCurrentPath)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                        Spacer()
                        Button {
                            Task { await vm.remoteBack() }
                        } label: {
                            Image(systemName: "chevron.backward")
                        }
                        .help("Back")
                        .font(.caption)
                        .disabled(vm.isBusy || !vm.canRemoteBack)
                        Button {
                            Task { await vm.remoteForward() }
                        } label: {
                            Image(systemName: "chevron.forward")
                        }
                        .help("Forward")
                        .font(.caption)
                        .disabled(vm.isBusy || !vm.canRemoteForward)
                        Button {
                            pendingDeleteTarget = .remote
                        } label: {
                            Image(systemName: "trash")
                        }
                        .help("Delete selected remote item(s)")
                        .font(.caption)
                        .disabled(vm.isBusy || vm.selectedRemoteEntryIDs.isEmpty || vm.deviceSerial.isEmpty)
                        Button {
                            Task { await vm.downloadSelectedRemoteToLocal() }
                        } label: {
                            Image(systemName: "arrow.down.to.line.compact")
                        }
                        .help("Transfer selected Android item(s) to Mac folder")
                        .font(.caption)
                        .disabled(vm.isBusy || vm.selectedRemoteEntryIDs.isEmpty || vm.deviceSerial.isEmpty)
                        Button {
                            Task { await vm.refreshRemoteDirectory() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .help("Refresh Android pane")
                        .font(.caption)
                        .disabled(vm.isBusy || vm.deviceSerial.isEmpty)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)

                    Divider()

                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(vm.remoteEntries) { entry in
                                HStack(spacing: 10) {
                                    Button {
                                        vm.toggleRemoteSelection(id: entry.id)
                                    } label: {
                                        Image(systemName: vm.selectedRemoteEntryIDs.contains(entry.id) ? "checkmark.square.fill" : "square")
                                            .foregroundStyle(vm.selectedRemoteEntryIDs.contains(entry.id) ? Color.accentColor : Color.secondary)
                                    }
                                    .buttonStyle(.plain)
                                    Image(systemName: entry.isDirectory ? "folder" : "doc")
                                    Text(entry.name)
                                        .lineLimit(1)
                                    Spacer()
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(remoteRowBackgroundColor(for: entry.id))
                                .contentShape(Rectangle())
                                .onHover { isHovering in
                                    hoveredRemoteEntryID = isHovering ? entry.id : nil
                                }
                                .onTapGesture {
                                    let isCommand = NSEvent.modifierFlags.contains(.command)
                                    vm.handleRemoteRowSelection(id: entry.id, commandPressed: isCommand)
                                }
                                .simultaneousGesture(TapGesture(count: 2).onEnded {
                                    guard entry.isDirectory else { return }
                                    vm.handleRemoteRowSelection(id: entry.id, commandPressed: false)
                                    Task { await vm.openRemoteDirectory(entry) }
                                })
                            }
                        }
                    }
                    .id("remote-\(vm.remoteCurrentPath)-\(vm.remoteListRevision)")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                Divider()
                    .frame(maxHeight: .infinity)

                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Button {
                            vm.toggleSelectAllLocal()
                        } label: {
                            Image(systemName: vm.isAllLocalSelected ? "checkmark.square.fill" : "square")
                                .foregroundStyle(vm.isAllLocalSelected ? Color.accentColor : Color.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Select/Deselect all in Mac pane")
                        Text("Mac")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(vm.localCurrentPath)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                        Spacer()
                        Button {
                            vm.localBack()
                        } label: {
                            Image(systemName: "chevron.backward")
                        }
                        .help("Back")
                        .font(.caption)
                        .disabled(vm.isBusy || !vm.canLocalBack)
                        Button {
                            vm.localForward()
                        } label: {
                            Image(systemName: "chevron.forward")
                        }
                        .help("Forward")
                        .font(.caption)
                        .disabled(vm.isBusy || !vm.canLocalForward)
                        Button {
                            pendingDeleteTarget = .local
                        } label: {
                            Image(systemName: "trash")
                        }
                        .help("Delete selected local item(s)")
                        .font(.caption)
                        .disabled(vm.isBusy || vm.selectedLocalEntryIDs.isEmpty)
                        Button {
                            Task { await vm.uploadSelectedLocalToRemote() }
                        } label: {
                            Image(systemName: "arrow.up.to.line.compact")
                        }
                        .help("Transfer selected Mac item(s) to Android folder")
                        .font(.caption)
                        .disabled(vm.isBusy || vm.selectedLocalEntryIDs.isEmpty || vm.deviceSerial.isEmpty)
                        Button {
                            do {
                                try vm.refreshLocalDirectory()
                                vm.status = "Loaded \(vm.localEntries.count) items from \(vm.localCurrentPath)."
                            } catch {
                                vm.status = "Failed to refresh local files: \(error.localizedDescription)"
                            }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .help("Refresh Mac pane")
                        .font(.caption)
                        .disabled(vm.isBusy)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)

                    Divider()

                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(vm.localEntries) { entry in
                                HStack(spacing: 10) {
                                    Button {
                                        vm.toggleLocalSelection(id: entry.id)
                                    } label: {
                                        Image(systemName: vm.selectedLocalEntryIDs.contains(entry.id) ? "checkmark.square.fill" : "square")
                                            .foregroundStyle(vm.selectedLocalEntryIDs.contains(entry.id) ? Color.accentColor : Color.secondary)
                                    }
                                    .buttonStyle(.plain)
                                    Image(systemName: entry.isDirectory ? "folder" : "doc")
                                    Text(entry.name)
                                        .lineLimit(1)
                                    Spacer()
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(localRowBackgroundColor(for: entry.id))
                                .contentShape(Rectangle())
                                .onHover { isHovering in
                                    hoveredLocalEntryID = isHovering ? entry.id : nil
                                }
                                .onTapGesture {
                                    let isCommand = NSEvent.modifierFlags.contains(.command)
                                    vm.handleLocalRowSelection(id: entry.id, commandPressed: isCommand)
                                }
                                .simultaneousGesture(TapGesture(count: 2).onEnded {
                                    guard entry.isDirectory else { return }
                                    vm.handleLocalRowSelection(id: entry.id, commandPressed: false)
                                    vm.openLocalDirectory(entry)
                                })
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            VStack(spacing: 0) {
                ZStack {
                    Divider()
                    Rectangle()
                        .fill(Color.clear)
                        .frame(height: 12)
                }
                .contentShape(Rectangle())
                .onHover { isHovering in
                    if isHovering {
                        NSCursor.resizeUpDown.set()
                    } else {
                        NSCursor.arrow.set()
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if footerDragStartHeight == nil {
                                footerDragStartHeight = footerHeight
                            }
                            let start = footerDragStartHeight ?? footerHeight
                            let resized = start - value.translation.height
                            footerHeight = min(max(resized, 90), 420)
                        }
                        .onEnded { _ in
                            footerDragStartHeight = nil
                        }
                )

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(vm.status)
                            .font(.caption)
                            .lineLimit(2)
                        Spacer()
                        if vm.hasTransferQueue {
                            Button("Clear Queue") {
                                vm.clearQueue()
                            }
                            .font(.caption)
                            .disabled(vm.isBusy)
                        }
                        if vm.isBusy {
                            Button("Cancel All") {
                                vm.cancelAllTransfers()
                            }
                            .font(.caption)
                        }
                    }

                    if vm.hasTransferQueue {
                        Text("Transfer Queue")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        ScrollView {
                            LazyVStack(spacing: 6) {
                                ForEach(vm.transferTasks) { task in
                                    HStack(spacing: 8) {
                                        Image(systemName: task.direction == .download ? "arrow.down.circle" : "arrow.up.circle")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Text(task.direction.rawValue)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)

                                        Text(task.name)
                                            .font(.caption)
                                            .lineLimit(1)

                                        Spacer()

                                        Text(task.state.label)
                                            .font(.caption2)
                                            .foregroundStyle(stateColor(task.state))

                                        if task.state == .pending {
                                            Button("Cancel") {
                                                vm.cancelPendingTransfer(id: task.id)
                                            }
                                            .font(.caption2)
                                        }
                                    }
                                    if task.state == .inProgress {
                                        IndeterminateProgressBar()
                                            .frame(maxWidth: .infinity)
                                    } else if task.state == .completed {
                                        ProgressView(value: 100, total: 100)
                                            .frame(maxWidth: .infinity)
                                    }
                                }
                            }
                        }
                        .frame(minHeight: 60, maxHeight: .infinity)
                    }
                }
                .padding(12)
            }
            .frame(height: vm.hasTransferQueue ? footerHeight : 90)
        }
        .frame(minWidth: 840, minHeight: 620)
        .task {
            await vm.initialize()
        }
        .confirmationDialog(
            pendingDeleteTarget == .remote ? "Delete selected remote item(s)?" : "Delete selected local item(s)?",
            isPresented: Binding(
                get: { pendingDeleteTarget != nil },
                set: { if !$0 { pendingDeleteTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let target = pendingDeleteTarget else { return }
                pendingDeleteTarget = nil
                switch target {
                case .remote:
                    Task { await vm.deleteSelectedRemote() }
                case .local:
                    vm.deleteSelectedLocal()
                }
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteTarget = nil
            }
        } message: {
            if pendingDeleteTarget == .remote {
                Text("This will permanently delete selected files/folders from your Android device.")
            } else {
                Text("This will permanently delete selected files/folders from your Mac.")
            }
        }
    }

    private func remoteRowBackgroundColor(for id: String) -> Color {
        if vm.selectedRemoteEntryIDs.contains(id) {
            return Color.accentColor.opacity(0.22)
        }
        if hoveredRemoteEntryID == id {
            return Color.accentColor.opacity(0.08)
        }
        return .clear
    }

    private func localRowBackgroundColor(for id: String) -> Color {
        if vm.selectedLocalEntryIDs.contains(id) {
            return Color.accentColor.opacity(0.22)
        }
        if hoveredLocalEntryID == id {
            return Color.accentColor.opacity(0.08)
        }
        return .clear
    }

    private func stateColor(_ state: TransferTaskState) -> Color {
        switch state {
        case .pending: return .secondary
        case .inProgress: return .blue
        case .completed: return .green
        case .cancelled: return .orange
        case .failed: return .red
        }
    }
}

@main
struct AndroidFileTransferApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
