import Foundation

struct ProcessResult {
    let exitCode: Int32
    /// Tail of stdout/stderr only — a 4-hour whisper run prints tens of
    /// thousands of lines and we only ever need the end for diagnostics.
    let stdout: String
    let stderr: String

    var succeeded: Bool { exitCode == 0 }
}

enum ShellError: LocalizedError {
    case launchFailed(String, underlying: Error)
    case nonZeroExit(tool: String, code: Int32, stderrTail: String)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let tool, let underlying):
            return "Could not launch \(tool): \(underlying.localizedDescription)"
        case .nonZeroExit(let tool, let code, let tail):
            return "\(tool) exited with code \(code).\n\(tail)"
        }
    }
}

/// Collects process output, hands complete lines to callbacks, and keeps only a
/// bounded tail in memory.
private final class OutputCollector {
    private let lock = NSLock()
    private let maxTail = 64 * 1024

    private var outTail = ""
    private var errTail = ""
    private var outPartial = ""
    private var errPartial = ""

    private let onOut: ((String) -> Void)?
    private let onErr: ((String) -> Void)?

    init(onOut: ((String) -> Void)?, onErr: ((String) -> Void)?) {
        self.onOut = onOut
        self.onErr = onErr
    }

    var stdout: String { lock.withLock { outTail } }
    var stderr: String { lock.withLock { errTail } }

    func drain(_ handle: FileHandle, isError: Bool) {
        while true {
            let data = handle.availableData
            if data.isEmpty { break }
            let chunk = String(decoding: data, as: UTF8.self)
            ingest(chunk, isError: isError)
        }
        flushPartial(isError: isError)
    }

    private func ingest(_ chunk: String, isError: Bool) {
        var lines: [String] = []
        lock.withLock {
            if isError {
                errTail += chunk
                if errTail.count > maxTail { errTail = String(errTail.suffix(maxTail)) }
                errPartial += chunk
                lines = splitLines(&errPartial)
            } else {
                outTail += chunk
                if outTail.count > maxTail { outTail = String(outTail.suffix(maxTail)) }
                outPartial += chunk
                lines = splitLines(&outPartial)
            }
        }
        let callback = isError ? onErr : onOut
        guard let callback else { return }
        for line in lines where !line.isEmpty { callback(line) }
    }

    /// ffmpeg reports progress with carriage returns, whisper with newlines, so
    /// both count as line terminators.
    private func splitLines(_ buffer: inout String) -> [String] {
        var lines: [String] = []
        while let idx = buffer.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
            lines.append(String(buffer[buffer.startIndex..<idx]))
            buffer = String(buffer[buffer.index(after: idx)...])
        }
        return lines
    }

    private func flushPartial(isError: Bool) {
        var remainder = ""
        lock.withLock {
            if isError { remainder = errPartial; errPartial = "" }
            else { remainder = outPartial; outPartial = "" }
        }
        guard !remainder.isEmpty else { return }
        (isError ? onErr : onOut)?(remainder)
    }
}

/// Single choke point for launching external tools. Everything video- or
/// audio-related in this app is ffmpeg or whisper-cli behind this call.
enum Shell {
    @discardableResult
    static func run(
        _ executable: URL,
        arguments: [String],
        onOutputLine: ((String) -> Void)? = nil,
        onErrorLine: ((String) -> Void)? = nil
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        // GUI apps inherit a bare PATH; tools are always invoked by absolute
        // path, but child processes (ffmpeg's helpers) benefit from a sane one.
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        let collector = OutputCollector(onOut: onOutputLine, onErr: onErrorLine)
        let toolName = executable.lastPathComponent

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, Error>) in
                let drained = DispatchGroup()
                drained.enter()
                drained.enter()

                DispatchQueue.global(qos: .userInitiated).async {
                    collector.drain(outPipe.fileHandleForReading, isError: false)
                    drained.leave()
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    collector.drain(errPipe.fileHandleForReading, isError: true)
                    drained.leave()
                }

                process.terminationHandler = { proc in
                    // Both pipes hit EOF as soon as the child exits, so this
                    // wait is short.
                    drained.wait()
                    continuation.resume(returning: ProcessResult(
                        exitCode: proc.terminationStatus,
                        stdout: collector.stdout,
                        stderr: collector.stderr
                    ))
                }

                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: ShellError.launchFailed(toolName, underlying: error))
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    /// Same as `run`, but throws when the tool reports failure.
    @discardableResult
    static func runChecked(
        _ executable: URL,
        arguments: [String],
        onOutputLine: ((String) -> Void)? = nil,
        onErrorLine: ((String) -> Void)? = nil
    ) async throws -> ProcessResult {
        let result = try await run(executable, arguments: arguments,
                                   onOutputLine: onOutputLine, onErrorLine: onErrorLine)
        try Task.checkCancellation()
        guard result.succeeded else {
            throw ShellError.nonZeroExit(
                tool: executable.lastPathComponent,
                code: result.exitCode,
                stderrTail: String(result.stderr.suffix(2000))
            )
        }
        return result
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
