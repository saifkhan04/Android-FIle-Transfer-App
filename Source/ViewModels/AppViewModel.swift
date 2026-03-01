import Foundation
import Combine

@MainActor
final class AppViewModel: ObservableObject {
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

    private let remoteBackend: RemoteFileBackend
    private var activeProcess: Process?
    private var transferCancelledByUser: Bool = false
    private var remoteHistory: [String] = []
    private var remoteHistoryIndex: Int = -1
    private var localHistory: [String] = []
    private var localHistoryIndex: Int = -1

    init(remoteBackend: RemoteFileBackend = ADBRemoteFileBackend()) {
        self.remoteBackend = remoteBackend
    }

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

        guard remoteBackend.isAvailable else {
            status = remoteBackend.unavailableReason ?? "Remote backend unavailable."
            return
        }

        await refreshDevicesAndFiles()
    }

    func refreshDevicesAndFiles() async {
        guard remoteBackend.isAvailable else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            let devices = try await remoteBackend.listDevices()
            guard let first = devices.first else {
                deviceSerial = ""
                deviceDisplayName = "None"
                remoteEntries = []
                selectedRemoteEntryIDs = []
                status = "No Android device detected. Connect phone and enable USB debugging."
                return
            }

            deviceSerial = first.id
            deviceDisplayName = first.displayName
            status = "Connected to \(deviceDisplayName)."
            let snapshot = try await remoteBackend.listDirectory(serial: deviceSerial, path: remoteCurrentPath)
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
        guard !deviceSerial.isEmpty else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            let snapshot = try await remoteBackend.listDirectory(serial: deviceSerial, path: remoteCurrentPath)
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
                try await remoteBackend.deleteRemote(serial: deviceSerial, path: entry.fullPath)
            }
            status = "Deleted \(selected.count) remote item(s)."
            let snapshot = try await remoteBackend.listDirectory(serial: deviceSerial, path: remoteCurrentPath)
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
                try await remoteBackend.pushWithProgress(
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
            let snapshot = try await remoteBackend.listDirectory(serial: deviceSerial, path: remoteCurrentPath)
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
                    let files = try await remoteBackend.listFilesRecursively(serial: deviceSerial, path: entry.fullPath)

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
                try await remoteBackend.pullWithProgress(
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
