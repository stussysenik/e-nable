// --------------------------------------------------------------------------
// ADBBridge.swift - ADB reverse tunnel management for USB transport
//
// Manages the ADB reverse tunnel that lets the Boox app reach the Mac's
// TCP server over USB-C. The Boox connects to localhost:<devicePort>,
// which ADB forwards to the Mac's localhost:<hostPort>.
//
// Learning note (Foundation.Process):
//   Foundation's Process (née NSTask) is Swift's way to spawn subprocesses.
//   We capture stdout/stderr via Pipe objects attached to the process. The
//   output is only available after the process terminates or flushes, so
//   we read after waitUntilExit() returns.
//
// Learning note (shell environment):
//   GUI apps on macOS don't inherit the user's shell PATH. ADB is often
//   installed via Homebrew or Android Studio, which modify PATH in
//   ~/.zshrc or ~/.bash_profile. We load these variables by spawning a
//   login shell and printing the environment, then parse the result.
// --------------------------------------------------------------------------

import Foundation

/// Errors that can occur during ADB bridge operations.
///
/// Each case provides an actionable message so the UI layer can guide
/// the user toward a fix without needing to interpret raw shell output.
public enum ADBError: LocalizedError, Sendable {

    /// The `adb` binary could not be found in PATH or ANDROID_HOME.
    case adbNotFound

    /// `adb devices` returned no connected device.
    case noDeviceConnected

    /// `adb reverse` command failed with a non-zero exit code.
    case tunnelSetupFailed(stderr: String)

    /// A generic process execution failure (e.g., permission denied).
    case processError(String)

    public var errorDescription: String? {
        switch self {
        case .adbNotFound:
            return "ADB not found. Install Android SDK Platform Tools or set ANDROID_HOME."
        case .noDeviceConnected:
            return "No device found. Connect your Boox tablet via USB."
        case .tunnelSetupFailed(let stderr):
            return "ADB reverse tunnel setup failed: \(stderr)"
        case .processError(let msg):
            return "ADB process error: \(msg)"
        }
    }
}

// MARK: - ADBBridge

/// Manages ADB reverse tunnel lifecycle for USB-C transport.
///
/// Usage:
/// ```swift
/// let bridge = ADBBridge()
/// try await bridge.setupReverseTunnel(devicePort: 8888, hostPort: 8888)
/// // ... mirroring session ...
/// try await bridge.teardownReverseTunnel(devicePort: 8888)
/// ```
///
/// The bridge resolves the ADB binary path by checking:
/// 1. `ANDROID_HOME/platform-tools/adb`
/// 2. The user's shell PATH (loaded from their profile)
/// 3. Common installation directories (/usr/local/bin, ~/Library/Android/sdk)
///
/// Learning note (actors vs. classes):
///   We use a plain final class here rather than an actor because ADB
///   operations are inherently serialized (one shell command at a time)
///   and callers use async/await. Making it an actor would add unnecessary
///   hop overhead for what is fundamentally a sequential command runner.
public final class ADBBridge: Sendable {

    /// Common paths where ADB might be installed on macOS.
    /// Checked in order after ANDROID_HOME and shell PATH.
    private static let fallbackPaths: [String] = [
        "/usr/local/bin/adb",
        "/opt/homebrew/bin/adb",
    ]

    public init() {}

    // MARK: - Public API

    /// Set up an ADB reverse tunnel mapping `devicePort` on the Boox
    /// to `hostPort` on the Mac.
    ///
    /// This runs `adb reverse tcp:<devicePort> tcp:<hostPort>`. If a tunnel
    /// already exists on that port, ADB silently replaces it.
    ///
    /// - Parameters:
    ///   - devicePort: TCP port on the Android device (default 8888).
    ///   - hostPort: TCP port on the Mac host (default 8888).
    /// - Throws: `ADBError` if ADB is missing, no device is connected, or the command fails.
    public func setupReverseTunnel(devicePort: UInt16 = 8888, hostPort: UInt16 = 8888) async throws {
        let adbPath = try await resolveADBPath()

        // Verify a device is connected before attempting the tunnel.
        try await verifyDeviceConnected(adbPath: adbPath)

        // Set up the reverse tunnel.
        let result = try await runProcess(
            executablePath: adbPath,
            arguments: ["reverse", "tcp:\(devicePort)", "tcp:\(hostPort)"]
        )

        if result.exitCode != 0 {
            throw ADBError.tunnelSetupFailed(stderr: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Remove a previously established ADB reverse tunnel.
    ///
    /// - Parameter devicePort: The device port to unmap.
    /// - Throws: `ADBError` on failure. Non-fatal if the tunnel was already removed.
    public func teardownReverseTunnel(devicePort: UInt16 = 8888) async throws {
        let adbPath = try await resolveADBPath()

        let result = try await runProcess(
            executablePath: adbPath,
            arguments: ["reverse", "--remove", "tcp:\(devicePort)"]
        )

        // Exit code 1 is acceptable — means the tunnel didn't exist.
        if result.exitCode != 0 && result.exitCode != 1 {
            throw ADBError.tunnelSetupFailed(stderr: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Remove all ADB reverse tunnels. Useful for clean shutdown.
    public func teardownAllReverseTunnels() async throws {
        let adbPath = try await resolveADBPath()

        _ = try await runProcess(
            executablePath: adbPath,
            arguments: ["reverse", "--remove-all"]
        )
    }

    /// Check if a USB device is currently connected via ADB.
    ///
    /// - Returns: `true` if at least one device is listed by `adb devices`.
    public func isDeviceConnected() async -> Bool {
        guard let adbPath = try? await resolveADBPath() else { return false }
        guard let result = try? await runProcess(
            executablePath: adbPath,
            arguments: ["devices"]
        ) else { return false }

        // `adb devices` output format:
        //   List of devices attached
        //   <serial>\tdevice
        //
        // We look for lines containing "device" (not "offline" or "unauthorized").
        let lines = result.stdout.components(separatedBy: .newlines)
        return lines.contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasSuffix("device") && !trimmed.hasPrefix("List")
        }
    }

    // MARK: - ADB Path Resolution

    /// Locate the `adb` binary by searching environment, shell profile, and common paths.
    ///
    /// Learning note (why this is complex):
    ///   macOS GUI processes don't inherit the user's shell PATH. An app launched
    ///   from Finder or Spotlight has a minimal PATH that typically doesn't include
    ///   Homebrew or Android Studio directories. We must actively search for ADB.
    private func resolveADBPath() async throws -> String {
        // 1. Check ANDROID_HOME environment variable.
        if let androidHome = ProcessInfo.processInfo.environment["ANDROID_HOME"] {
            let candidate = "\(androidHome)/platform-tools/adb"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        // 2. Check HOME-relative Android SDK path (Android Studio default).
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let androidStudioPath = "\(home)/Library/Android/sdk/platform-tools/adb"
        if FileManager.default.isExecutableFile(atPath: androidStudioPath) {
            return androidStudioPath
        }

        // 3. Try `which adb` using the user's shell to pick up their PATH.
        if let shellPath = try? await resolveViaShell() {
            return shellPath
        }

        // 4. Check common fallback locations.
        for path in Self.fallbackPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        throw ADBError.adbNotFound
    }

    /// Resolve ADB path by running `which adb` in a login shell.
    ///
    /// This spawns a login shell (`zsh -l` or `bash -l`) which sources the
    /// user's profile, giving us the full PATH they configured.
    private func resolveViaShell() async throws -> String? {
        // Determine the user's default shell.
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"

        let result = try await runProcess(
            executablePath: shell,
            arguments: ["-l", "-c", "which adb"]
        )

        guard result.exitCode == 0 else { return nil }

        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else {
            return nil
        }

        return path
    }

    /// Verify that at least one ADB device is connected and authorized.
    private func verifyDeviceConnected(adbPath: String) async throws {
        let result = try await runProcess(
            executablePath: adbPath,
            arguments: ["devices"]
        )

        guard result.exitCode == 0 else {
            throw ADBError.processError("adb devices failed with exit code \(result.exitCode)")
        }

        let lines = result.stdout.components(separatedBy: .newlines)
        let hasDevice = lines.contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasSuffix("device") && !trimmed.hasPrefix("List")
        }

        guard hasDevice else {
            throw ADBError.noDeviceConnected
        }
    }

    // MARK: - Process Execution

    /// Result of a subprocess execution.
    private struct ProcessResult: Sendable {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    /// Run a subprocess and capture its output.
    ///
    /// Learning note (async subprocess execution):
    ///   Foundation.Process is synchronous (waitUntilExit blocks the calling thread).
    ///   We wrap it in a detached Task to avoid blocking the cooperative thread pool.
    ///   The @Sendable closure captures only Sendable values (strings), keeping
    ///   Swift 6 concurrency checking happy.
    private func runProcess(executablePath: String, arguments: [String]) async throws -> ProcessResult {
        let execPath = executablePath
        let args = arguments

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: execPath)
                process.arguments = args

                // Inherit a useful PATH so child processes (e.g. adb spawning server)
                // can find their dependencies.
                var env = ProcessInfo.processInfo.environment
                let extraPaths = [
                    "/usr/local/bin",
                    "/opt/homebrew/bin",
                    "\(FileManager.default.homeDirectoryForCurrentUser.path)/Library/Android/sdk/platform-tools",
                ]
                let existingPath = env["PATH"] ?? "/usr/bin:/bin"
                env["PATH"] = (extraPaths + [existingPath]).joined(separator: ":")
                process.environment = env

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                do {
                    try process.run()
                    process.waitUntilExit()

                    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                    let result = ProcessResult(
                        exitCode: process.terminationStatus,
                        stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                        stderr: String(data: stderrData, encoding: .utf8) ?? ""
                    )
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: ADBError.processError(error.localizedDescription))
                }
            }
        }
    }
}
