import Foundation

final class ADBRemoteFileBackend: RemoteFileBackend {
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

    private let adbPath: String?

    init(adbPath: String? = ADBRemoteFileBackend.findADB()) {
        self.adbPath = adbPath
    }

    var isAvailable: Bool {
        adbPath?.isEmpty == false
    }

    var unavailableReason: String? {
        guard !isAvailable else { return nil }
        return "adb not found. Install Android Platform Tools and ensure adb is in PATH."
    }

    func listDevices() async throws -> [ConnectedDevice] {
        let adb = try requireADBPath()
        let serials = try await listDeviceSerials(adbPath: adb)
        var devices: [ConnectedDevice] = []
        devices.reserveCapacity(serials.count)

        for serial in serials {
            let displayName = (try? await friendlyDeviceName(adbPath: adb, serial: serial)) ?? serial
            devices.append(ConnectedDevice(id: serial, displayName: displayName))
        }
        return devices
    }

    func listDirectory(serial: String, path: String) async throws -> DirectorySnapshot {
        let adb = try requireADBPath()
        let resolvedPath = normalizePath(path)
        let output = try await run(adb, ["-s", serial, "shell", "ls", "-1Ap", shellEscapeForShell(resolvedPath)])
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
            let fullPath = Self.joinRemotePath(parent: resolvedPath, child: name)
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

    func listFilesRecursively(serial: String, path: String) async throws -> [String] {
        let adb = try requireADBPath()
        let output = try await run(adb, ["-s", serial, "shell", "find", shellEscapeForShell(path), "-type", "f"])
        return output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.hasPrefix("/") }
            .sorted()
    }

    func pullWithProgress(
        serial: String,
        remotePath: String,
        localDirectory: String,
        onProcessStarted: @escaping (Process) -> Void,
        onProgress: @escaping (Double) -> Void
    ) async throws {
        let adb = try requireADBPath()
        _ = try await runWithProgress(
            executable: adb,
            args: ["-s", serial, "pull", "-p", remotePath, localDirectory],
            onProcessStarted: onProcessStarted,
            onProgress: onProgress
        )
    }

    func pushWithProgress(
        serial: String,
        localPath: String,
        remoteDirectory: String,
        onProcessStarted: @escaping (Process) -> Void,
        onProgress: @escaping (Double) -> Void
    ) async throws {
        let adb = try requireADBPath()
        _ = try await runWithProgress(
            executable: adb,
            args: ["-s", serial, "push", "-p", localPath, remoteDirectory],
            onProcessStarted: onProcessStarted,
            onProgress: onProgress
        )
    }

    func deleteRemote(serial: String, path: String) async throws {
        let adb = try requireADBPath()
        _ = try await run(adb, ["-s", serial, "shell", "rm", "-rf", "--", shellEscapeForShell(path)])
    }

    private func requireADBPath() throws -> String {
        guard let adbPath, !adbPath.isEmpty else {
            throw BackendError.commandFailed(unavailableReason ?? "adb not available")
        }
        return adbPath
    }

    private func listDeviceSerials(adbPath: String) async throws -> [String] {
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

    private func friendlyDeviceName(adbPath: String, serial: String) async throws -> String {
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

    private static func findADB() -> String? {
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

    private static func joinRemotePath(parent: String, child: String) -> String {
        let normalizedParent = parent == "/" ? "" : parent.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if parent == "/" {
            return "/\(child)"
        }
        return "/\(normalizedParent)/\(child)"
    }

    private func normalizePath(_ path: String) -> String {
        var p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.isEmpty { p = "/sdcard" }
        if !p.hasPrefix("/") { p = "/" + p }
        while p.count > 1 && p.hasSuffix("/") {
            p.removeLast()
        }
        return p
    }

    private func readProp(adbPath: String, serial: String, key: String) async throws -> String {
        let value = try await run(adbPath, ["-s", serial, "shell", "getprop", key])
        return value.replacingOccurrences(of: "\r", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // adb shell still invokes remote shell parsing; quote paths so characters like () are safe.
    private func shellEscapeForShell(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private func run(_ executable: String, _ args: [String]) async throws -> String {
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
                    continuation.resume(throwing: BackendError.commandFailed(message.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func runWithProgress(
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
                if let percent = Self.extractPercent(from: chunk) {
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
                    continuation.resume(throwing: BackendError.commandFailed(message.isEmpty ? "adb transfer failed" : message))
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
