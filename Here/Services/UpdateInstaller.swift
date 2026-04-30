import AppKit
import Foundation

/// Replaces the running `/Applications/Here.app` with the contents of
/// a freshly-downloaded DMG, then relaunches.
///
/// Why this is shaped the way it is:
///
/// 1. **No Gatekeeper "open anyway" prompt.** macOS adds the
///    `com.apple.quarantine` extended attribute to anything LaunchServices
///    sees as a "downloaded from the internet" file — i.e. browsers,
///    Mail, AirDrop. URLSession-downloaded files don't get the xattr.
///    By fetching the DMG ourselves via URLSession, then `ditto`-copying
///    the bundle into `/Applications`, we never trip the Gatekeeper
///    first-run dialog.
///
/// 2. **Self-replacing without `chmod`/admin prompts.** Because we own
///    `/Applications/Here.app` (the user installed it) and we run as
///    that user, no privilege escalation is needed. `rm -rf` + `mv`
///    just works.
///
/// 3. **Survives our own exit.** The replace step has to happen *after*
///    Here quits — macOS won't let us overwrite a running bundle's
///    files cleanly. We write a tiny shell script to a temp path,
///    spawn it via `Process` with `stdin/out/err` redirected to
///    `/dev/null`, then `NSApp.terminate(nil)` ourselves. The script
///    polls for our PID to exit, then does the swap and `open`s the
///    new bundle. Because we never call `waitUntilExit`, the child is
///    reparented to launchd when we die, not killed alongside us.
actor UpdateInstaller {
    enum Phase: Sendable, Equatable {
        case downloading(progress: Double) // 0...1
        case mounting
        case copying
        case relaunching
        case failed(String)
    }

    enum InstallError: Error, LocalizedError, Sendable {
        case downloadFailed(String)
        case mountFailed(String)
        case copyFailed(String)
        case scriptFailed

        var errorDescription: String? {
            switch self {
            case .downloadFailed(let msg): "Couldn't download the update: \(msg)"
            case .mountFailed(let msg):    "Couldn't mount the image: \(msg)"
            case .copyFailed(let msg):     "Couldn't copy the new app: \(msg)"
            case .scriptFailed:            "Couldn't start the installer."
            }
        }
    }

    private let installPath = URL(filePath: "/Applications/Here.app")

    /// Returns a stream of phase updates. On success the stream
    /// finishes after `.relaunching` and the process is terminated;
    /// on failure it yields `.failed(reason)` and finishes.
    func install(dmgURL: URL) -> AsyncStream<Phase> {
        AsyncStream { continuation in
            Task {
                do {
                    let dmg = try await downloadDMG(from: dmgURL) { progress in
                        continuation.yield(.downloading(progress: progress))
                    }
                    continuation.yield(.mounting)
                    let mount = try await mount(dmg)

                    continuation.yield(.copying)
                    let staged = try copyApp(from: mount)
                    detach(mount)

                    continuation.yield(.relaunching)
                    try spawnRelauncher(stagedAppPath: staged)
                    continuation.finish()

                    // Exit so the relauncher's `wait for PID` loop
                    // returns. Must be on the main actor — NSApp is
                    // main-bound.
                    await MainActor.run { NSApp.terminate(nil) }
                } catch let error as InstallError {
                    continuation.yield(.failed(error.localizedDescription))
                    continuation.finish()
                } catch {
                    continuation.yield(.failed(error.localizedDescription))
                    continuation.finish()
                }
            }
        }
    }

    // MARK: - Steps

    private func downloadDMG(
        from url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 300
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let (asyncBytes, response) = try await session.bytes(from: url)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw InstallError.downloadFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        let total = response.expectedContentLength

        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("here-update-\(UUID().uuidString).dmg")
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        let handle = try FileHandle(forWritingTo: dest)
        defer { try? handle.close() }

        var buffer = Data()
        buffer.reserveCapacity(64_000)
        var written: Int64 = 0
        for try await byte in asyncBytes {
            buffer.append(byte)
            if buffer.count >= 64_000 {
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if total > 0 { progress(Double(written) / Double(total)) }
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
        }
        progress(1.0)
        return dest
    }

    private func mount(_ dmgPath: URL) async throws -> URL {
        let task = Process()
        task.executableURL = URL(filePath: "/usr/bin/hdiutil")
        task.arguments = ["attach", "-nobrowse", "-noverify", "-noautoopen", dmgPath.path]
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe
        try task.run()
        task.waitUntilExit()

        let stderr = (try? errPipe.fileHandleForReading.readToEnd())
            .flatMap { String(data: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
        guard task.terminationStatus == 0 else {
            throw InstallError.mountFailed(stderr.isEmpty ? "exit \(task.terminationStatus)" : stderr)
        }

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        // hdiutil output: each line is `<dev>\t<type>\t<mount-path>`.
        // The mount path is always under `/Volumes/`.
        for line in output.split(separator: "\n") {
            for field in line.split(separator: "\t") {
                let path = String(field).trimmingCharacters(in: .whitespaces)
                if path.hasPrefix("/Volumes/") {
                    return URL(filePath: path)
                }
            }
        }
        throw InstallError.mountFailed("no /Volumes path in attach output")
    }

    private func copyApp(from mount: URL) throws -> URL {
        let source = mount.appendingPathComponent("Here.app")
        let stagingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("here-staged-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let dest = stagingDir.appendingPathComponent("Here.app")
        let task = Process()
        task.executableURL = URL(filePath: "/usr/bin/ditto")
        task.arguments = [source.path, dest.path]
        let errPipe = Pipe()
        task.standardError = errPipe
        try task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            let stderr = (try? errPipe.fileHandleForReading.readToEnd())
                .flatMap { String(data: $0, encoding: .utf8) }?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "exit \(task.terminationStatus)"
            throw InstallError.copyFailed(stderr)
        }
        return dest
    }

    private func detach(_ mount: URL) {
        let task = Process()
        task.executableURL = URL(filePath: "/usr/bin/hdiutil")
        task.arguments = ["detach", mount.path, "-force"]
        try? task.run()
        task.waitUntilExit()
    }

    private func spawnRelauncher(stagedAppPath: URL) throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let install = installPath.path
        let staged = stagedAppPath.path

        // The script:
        //  - polls for our PID to exit (max ~10 s — anything longer
        //    means something's wrong and we'd rather error out than
        //    spin forever)
        //  - removes the old bundle, moves the staged one in
        //  - strips quarantine defensively (URLSession download
        //    shouldn't set it, but mount/copy paths through hdiutil
        //    occasionally inherit weird xattrs — clearing it costs
        //    nothing)
        //  - relaunches via `open`, so the new bundle's regular
        //    LaunchServices flow runs (Dock state, login items, etc.)
        //  - cleans up its own script file
        let script = """
        #!/bin/bash
        for _ in $(seq 1 100); do
            if ! kill -0 \(pid) 2>/dev/null; then break; fi
            sleep 0.1
        done
        rm -rf '\(install)' 2>/dev/null
        if ! mv '\(staged)' '\(install)'; then exit 1; fi
        xattr -dr com.apple.quarantine '\(install)' 2>/dev/null || true
        open '\(install)'
        rm -f "$0"
        """

        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("here-relauncher-\(UUID().uuidString).sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )

        let task = Process()
        task.executableURL = URL(filePath: "/bin/bash")
        task.arguments = [scriptURL.path]
        // Disconnect from our stdio so the child doesn't keep the
        // parent process alive on macOS via inherited handles.
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            throw InstallError.scriptFailed
        }
        // Don't `waitUntilExit` — the script outlives us by design.
    }
}
