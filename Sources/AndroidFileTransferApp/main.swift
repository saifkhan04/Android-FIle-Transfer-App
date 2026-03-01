import SwiftUI
import Foundation
import AppKit

struct RemoteEntry: Identifiable, Hashable {
    let name: String
    let fullPath: String
    let isDirectory: Bool

    var id: String { fullPath }
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
    @Published var currentPath: String = "/sdcard"
    @Published var entries: [RemoteEntry] = []
    @Published var selectedEntryID: String? = nil
    @Published var status: String = "Ready"
    @Published var isBusy: Bool = false
    @Published var debugInfo: String = ""
    @Published var listRevision: Int = 0
    @Published var localDestinationPath: String = (FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path ?? NSHomeDirectory())
    @Published var transferPercent: Double? = nil
    @Published var transferETASeconds: TimeInterval? = nil
    @Published var transferLabel: String = ""

    private var activeProcess: Process?
    private var transferCancelledByUser: Bool = false

    var selectedEntries: [RemoteEntry] {
        guard let id = selectedEntryID else { return [] }
        return entries.filter { $0.id == id }
    }

    func initialize() async {
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
                entries = []
                selectedEntryID = nil
                status = "No Android device detected. Connect phone and enable USB debugging."
                return
            }

            deviceSerial = first
            status = "Connected to \(deviceSerial)."
            let snapshot = try await ADBService.listDirectory(adbPath: adbPath, serial: deviceSerial, path: currentPath)
            apply(snapshot: snapshot)
        } catch {
            status = "Failed to refresh: \(error.localizedDescription)"
        }
    }

    func openDirectory(_ entry: RemoteEntry) async {
        guard entry.isDirectory else {
            status = "\(entry.name) is not a folder."
            return
        }
        currentPath = entry.fullPath
        await refreshDirectory()
    }

    func openSelectedEntry() async {
        guard let selectedID = selectedEntryID,
              let selected = entries.first(where: { $0.id == selectedID }) else {
            status = "Select a folder to open."
            return
        }

        await openDirectory(selected)
    }

    func goUp() async {
        guard currentPath != "/" else { return }
        let parent = (currentPath as NSString).deletingLastPathComponent
        currentPath = parent.isEmpty ? "/" : parent
        await refreshDirectory()
    }

    func refreshDirectory() async {
        guard !deviceSerial.isEmpty, !adbPath.isEmpty else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            let snapshot = try await ADBService.listDirectory(adbPath: adbPath, serial: deviceSerial, path: currentPath)
            apply(snapshot: snapshot)
            status = "Loaded \(entries.count) items from \(currentPath)."
        } catch {
            status = "Failed to list \(currentPath): \(error.localizedDescription)"
        }
    }

    func downloadSelectedWithPicker() async {
        guard !selectedEntries.isEmpty else {
            status = "Select one or more files/folders to download."
            return
        }
        guard !localDestinationPath.isEmpty else {
            status = "Choose a local destination folder first."
            return
        }

        await downloadSelectedEntries(toDirectory: URL(fileURLWithPath: localDestinationPath))
    }

    func chooseLocalDestinationFolder() {
        let panel = NSOpenPanel()
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.title = "Choose default download destination"

        guard panel.runModal() == .OK, let destination = panel.url else {
            return
        }

        localDestinationPath = destination.path
        status = "Download destination set to \(destination.path)."
    }

    func cancelTransfer() {
        guard isBusy else { return }
        transferCancelledByUser = true
        activeProcess?.terminate()
    }

    func uploadFilesFromPicker() async {
        guard !deviceSerial.isEmpty else {
            status = "No device connected."
            return
        }

        let panel = NSOpenPanel()
        panel.prompt = "Upload"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.title = "Choose files/folders to upload"

        guard panel.runModal() == .OK else {
            status = "Upload cancelled."
            return
        }

        await uploadFiles(from: panel.urls)
    }

    private func uploadFiles(from urls: [URL]) async {
        guard !deviceSerial.isEmpty else {
            status = "No device connected."
            return
        }

        let localPaths = urls.map(\.path)
        guard !localPaths.isEmpty else {
            status = "No files to upload."
            return
        }

        isBusy = true
        transferCancelledByUser = false
        resetProgress()
        defer { isBusy = false }

        do {
            for (index, localPath) in localPaths.enumerated() {
                let itemName = URL(fileURLWithPath: localPath).lastPathComponent
                transferLabel = "Uploading \(itemName) (\(index + 1)/\(localPaths.count))"
                let start = Date()
                try await ADBService.pushWithProgress(
                    adbPath: adbPath,
                    serial: deviceSerial,
                    localPath: localPath,
                    remoteDirectory: currentPath,
                    onProcessStarted: { [weak self] process in
                        Task { @MainActor in
                            self?.activeProcess = process
                        }
                    },
                    onProgress: { [weak self] percent in
                        Task { @MainActor in
                            guard let self else { return }
                            self.updateProgress(percent: percent, start: start, index: index, total: localPaths.count)
                        }
                    }
                )
            }
            status = "Uploaded \(localPaths.count) item(s) to \(currentPath)."
            let snapshot = try await ADBService.listDirectory(adbPath: adbPath, serial: deviceSerial, path: currentPath)
            apply(snapshot: snapshot)
        } catch {
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

    private func downloadSelectedEntries(toDirectory destination: URL) async {
        let items = selectedEntries
        guard !items.isEmpty else {
            status = "Select one or more files/folders to download."
            return
        }

        isBusy = true
        transferCancelledByUser = false
        resetProgress()
        defer { isBusy = false }

        do {
            for (index, item) in items.enumerated() {
                transferLabel = "Downloading \(item.name) (\(index + 1)/\(items.count))"
                let start = Date()
                try await ADBService.pullWithProgress(
                    adbPath: adbPath,
                    serial: deviceSerial,
                    remotePath: item.fullPath,
                    localDirectory: destination.path,
                    onProcessStarted: { [weak self] process in
                        Task { @MainActor in
                            self?.activeProcess = process
                        }
                    },
                    onProgress: { [weak self] percent in
                        Task { @MainActor in
                            guard let self else { return }
                            self.updateProgress(percent: percent, start: start, index: index, total: items.count)
                        }
                    }
                )
            }
            status = "Downloaded \(items.count) item(s) to \(destination.path)."
        } catch {
            status = transferCancelledByUser ? "Download cancelled." : "Download failed: \(error.localizedDescription)"
        }
        resetProgress()
        activeProcess = nil
    }

    private func apply(snapshot: DirectorySnapshot) {
        entries = snapshot.entries
        currentPath = snapshot.resolvedPath
        selectedEntryID = nil
        listRevision += 1
        debugInfo = """
        Requested: \(snapshot.requestedPath)
        Resolved: \(snapshot.resolvedPath)
        Items: \(snapshot.entries.count)
        Raw:
        \(snapshot.rawListOutput)
        """
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
    @State private var showDebug: Bool = false
    @State private var hoveredEntryID: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button("Refresh") {
                    Task { await vm.refreshDevicesAndFiles() }
                }
                .disabled(vm.isBusy)

                Button("Up") {
                    Task { await vm.goUp() }
                }
                .disabled(vm.isBusy || vm.currentPath == "/")

                Button("Open") {
                    Task { await vm.openSelectedEntry() }
                }
                .disabled(vm.isBusy || vm.selectedEntryID == nil)

                Button("Upload") {
                    Task { await vm.uploadFilesFromPicker() }
                }
                .disabled(vm.isBusy || vm.deviceSerial.isEmpty)

                Button("Download") {
                    Task { await vm.downloadSelectedWithPicker() }
                }
                .disabled(vm.isBusy || vm.selectedEntries.isEmpty)

                Button("Choose Destination") {
                    vm.chooseLocalDestinationFolder()
                }
                .disabled(vm.isBusy)

                Spacer()

                Text("Device: \(vm.deviceSerial.isEmpty ? "None" : vm.deviceSerial)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)

            Divider()

            HStack {
                Text("Remote Path:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(vm.currentPath)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            HStack(spacing: 8) {
                Text("Local Destination:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(vm.localDestinationPath)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(vm.entries) { entry in
                        HStack(spacing: 10) {
                            Image(systemName: entry.isDirectory ? "folder" : "doc")
                            Text(entry.name)
                                .lineLimit(1)

                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(rowBackgroundColor(for: entry.id))
                        .contentShape(Rectangle())
                        .onHover { isHovering in
                            hoveredEntryID = isHovering ? entry.id : nil
                        }
                        .onTapGesture {
                            vm.selectedEntryID = entry.id
                        }
                        .simultaneousGesture(TapGesture(count: 2).onEnded {
                            guard entry.isDirectory else { return }
                            vm.selectedEntryID = entry.id
                            Task { await vm.openDirectory(entry) }
                        })
                    }
                }
            }
            .id("\(vm.currentPath)-\(vm.listRevision)")

            Divider()

            DisclosureGroup("Debug (ADB Listing)", isExpanded: $showDebug) {
                ScrollView {
                    Text(vm.debugInfo.isEmpty ? "No debug data yet." : vm.debugInfo)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(minHeight: 100, maxHeight: 180)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(vm.status)
                        .font(.caption)
                        .lineLimit(2)

                    if vm.isBusy || vm.transferPercent != nil {
                        HStack(spacing: 8) {
                            if let progress = vm.transferPercent {
                                FancyProgressBar(progress: progress)
                                    .frame(maxWidth: 280)
                                Text(vm.transferPercentText)
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                if !vm.formattedETA.isEmpty {
                                    Text("ETA \(vm.formattedETA)")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            } else {
                                IndeterminateProgressBar()
                                    .frame(maxWidth: 280)
                                Text("Working…")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Text(vm.transferLabel)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                Spacer()
                if vm.isBusy {
                    Button("Cancel") {
                        vm.cancelTransfer()
                    }
                    .font(.caption)
                }
            }
            .padding(12)
        }
        .frame(minWidth: 840, minHeight: 620)
        .task {
            await vm.initialize()
        }
    }

    private func rowBackgroundColor(for id: String) -> Color {
        if vm.selectedEntryID == id {
            return Color.accentColor.opacity(0.22)
        }
        if hoveredEntryID == id {
            return Color.accentColor.opacity(0.08)
        }
        return .clear
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
