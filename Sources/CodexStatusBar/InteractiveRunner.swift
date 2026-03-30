import Darwin
import Foundation

struct InteractiveRunner: Sendable {
    struct Result: Sendable {
        let output: String
        let exitCode: Int32
    }

    struct Options: Sendable {
        var timeout: TimeInterval
        var workingDirectory: URL?
        var arguments: [String]
        var autoResponses: [String: String]
        var environmentExclusions: [String]

        init(
            timeout: TimeInterval = 20,
            workingDirectory: URL? = nil,
            arguments: [String] = [],
            autoResponses: [String: String] = [:],
            environmentExclusions: [String] = []
        ) {
            self.timeout = timeout
            self.workingDirectory = workingDirectory
            self.arguments = arguments
            self.autoResponses = autoResponses
            self.environmentExclusions = environmentExclusions
        }
    }

    enum RunError: LocalizedError {
        case binaryNotFound(String)
        case launchFailed(String)
        case timedOut

        var errorDescription: String? {
            switch self {
            case let .binaryNotFound(binary):
                return "Could not find \(binary) on PATH."
            case let .launchFailed(reason):
                return "Failed to start the CLI process: \(reason)"
            case .timedOut:
                return "The CLI process did not finish before the timeout."
            }
        }
    }

    private static let terminalRows: UInt16 = 50
    private static let terminalCols: UInt16 = 160

    func run(binary: String, input: String, options: Options = Options()) throws -> Result {
        let executablePath = try findExecutable(binary)
        let (primaryFD, secondaryFD) = try openTerminal()

        _ = fcntl(primaryFD, F_SETFL, O_NONBLOCK)

        let primaryHandle = FileHandle(fileDescriptor: primaryFD, closeOnDealloc: true)
        let secondaryHandle = FileHandle(fileDescriptor: secondaryFD, closeOnDealloc: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = options.arguments
        process.standardInput = secondaryHandle
        process.standardOutput = secondaryHandle
        process.standardError = secondaryHandle
        process.environment = Self.terminalEnvironment(excluding: options.environmentExclusions)
        if let workingDirectory = options.workingDirectory {
            process.currentDirectoryURL = workingDirectory
        }

        var didLaunch = false
        defer {
            try? primaryHandle.close()
            try? secondaryHandle.close()

            if didLaunch, process.isRunning {
                process.terminate()
                let deadline = Date().addingTimeInterval(2)
                while process.isRunning, Date() < deadline {
                    usleep(100_000)
                }
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
                process.waitUntilExit()
            }
        }

        do {
            try process.run()
            didLaunch = true
        } catch {
            throw RunError.launchFailed(error.localizedDescription)
        }

        usleep(400_000)
        try sendInput(input, to: primaryHandle)

        let output = try captureOutput(
            from: primaryFD,
            handle: primaryHandle,
            process: process,
            options: options
        )

        guard let text = String(data: output, encoding: .utf8), !text.isEmpty else {
            throw RunError.timedOut
        }

        let exitCode: Int32 = process.isRunning ? -1 : process.terminationStatus
        return Result(output: text, exitCode: exitCode)
    }

    private func findExecutable(_ binary: String) throws -> String {
        if FileManager.default.isExecutableFile(atPath: binary) {
            return binary
        }

        let pathEntries = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)

        let defaultEntries = [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
            "/usr/bin",
            "/bin",
            "/Users/\(NSUserName())/.local/bin",
        ]

        for directory in pathEntries + defaultEntries where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(binary).path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        throw RunError.binaryNotFound(binary)
    }

    private func openTerminal() throws -> (primary: Int32, secondary: Int32) {
        var primaryFD: Int32 = -1
        var secondaryFD: Int32 = -1
        var terminalSize = winsize(
            ws_row: Self.terminalRows,
            ws_col: Self.terminalCols,
            ws_xpixel: 0,
            ws_ypixel: 0
        )

        guard openpty(&primaryFD, &secondaryFD, nil, nil, &terminalSize) == 0 else {
            throw RunError.launchFailed("Could not open a pseudo-terminal.")
        }

        return (primaryFD, secondaryFD)
    }

    private func sendInput(_ input: String, to handle: FileHandle) throws {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }

        if let data = (trimmed + "\r").data(using: .utf8) {
            try handle.write(contentsOf: data)
        }
    }

    private func captureOutput(
        from fd: Int32,
        handle: FileHandle,
        process: Process,
        options: Options
    ) throws -> Data {
        let deadline = Date().addingTimeInterval(options.timeout)
        let idleTimeout: TimeInterval = 3
        var buffer = Data()
        var lastMeaningfulDataTime = Date()

        let promptResponses = options.autoResponses.map {
            (prompt: Data($0.key.utf8), response: Data($0.value.utf8))
        }
        var respondedPrompts = Set<Data>()

        while Date() < deadline {
            let previousSize = buffer.count
            readAvailableData(from: fd, into: &buffer)

            if buffer.count > previousSize {
                let newData = buffer.suffix(from: previousSize)
                if isMeaningfulData(newData) {
                    lastMeaningfulDataTime = Date()
                }
            }

            for item in promptResponses where !respondedPrompts.contains(item.prompt) {
                if buffer.range(of: item.prompt) != nil {
                    try? handle.write(contentsOf: item.response)
                    respondedPrompts.insert(item.prompt)
                    lastMeaningfulDataTime = Date()
                }
            }

            if !process.isRunning {
                break
            }

            if hasMeaningfulContent(buffer),
               Date().timeIntervalSince(lastMeaningfulDataTime) > idleTimeout {
                break
            }

            usleep(60_000)
        }

        readAvailableData(from: fd, into: &buffer)
        return buffer
    }

    private func readAvailableData(from fd: Int32, into buffer: inout Data) {
        var chunk = [UInt8](repeating: 0, count: 8192)
        while true {
            let bytesRead = Darwin.read(fd, &chunk, chunk.count)
            if bytesRead > 0 {
                buffer.append(contentsOf: chunk.prefix(bytesRead))
            } else {
                break
            }
        }
    }

    private func isMeaningfulData<S: DataProtocol>(_ data: S) -> Bool {
        let value = Data(data)
        guard let text = String(data: value, encoding: .utf8) else {
            return !value.isEmpty
        }

        var stripped = text
        if let oscRegex = Self.oscRegex {
            stripped = oscRegex.stringByReplacingMatches(
                in: stripped,
                range: NSRange(stripped.startIndex..., in: stripped),
                withTemplate: ""
            )
        }

        stripped = stripped.replacingOccurrences(of: "\u{1B}", with: "")
        stripped = stripped.replacingOccurrences(of: "\u{07}", with: "")

        return !stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func hasMeaningfulContent(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else {
            return !data.isEmpty
        }

        var stripped = text.replacingOccurrences(
            of: #"\x1B\[[0-9;?]*[A-Za-z]"#,
            with: "",
            options: .regularExpression
        )
        stripped = stripped.replacingOccurrences(
            of: #"\x1B[\(\)][AB012]"#,
            with: "",
            options: .regularExpression
        )

        if let oscRegex = Self.oscRegex {
            stripped = oscRegex.stringByReplacingMatches(
                in: stripped,
                range: NSRange(stripped.startIndex..., in: stripped),
                withTemplate: ""
            )
        }

        stripped = stripped.replacingOccurrences(of: "\u{1B}", with: "")
        return !stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static let oscRegex = try? NSRegularExpression(
        pattern: #"\x1B\].*?(?:\x07|\x1B\\)"#,
        options: .dotMatchesLineSeparators
    )

    private static func terminalEnvironment(excluding: [String]) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        excluding.forEach { environment.removeValue(forKey: $0) }

        let existingPath = environment["PATH"] ?? ""
        let additions = [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
            "/Users/\(NSUserName())/.local/bin",
        ]

        var pathEntries = existingPath.split(separator: ":").map(String.init)
        for entry in additions where !pathEntries.contains(entry) && FileManager.default.fileExists(atPath: entry) {
            pathEntries.insert(entry, at: 0)
        }

        environment["PATH"] = pathEntries.joined(separator: ":")
        environment["HOME"] = environment["HOME"] ?? NSHomeDirectory()
        environment["TERM"] = environment["TERM"] ?? "xterm-256color"
        environment["COLORTERM"] = environment["COLORTERM"] ?? "truecolor"
        environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"
        environment["CI"] = environment["CI"] ?? "0"

        return environment
    }
}
