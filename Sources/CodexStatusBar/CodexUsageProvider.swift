import Foundation

struct CodexUsageMetric: Sendable, Identifiable {
    let id: String
    let title: String
    let percentUsed: Int
    let percentRemaining: Int
    let resetText: String?
}

struct CodexUsageSnapshot: Sendable {
    let primaryPercentUsed: Int
    let primaryPercentRemaining: Int
    let primaryResetText: String?
    let secondaryPercentUsed: Int?
    let secondaryPercentRemaining: Int?
    let secondaryResetText: String?
    let accountLabel: String?
    let metrics: [CodexUsageMetric]
}

struct CodexUsageProvider: Sendable {
    let sessionsDirectoryURL: URL

    init(sessionsDirectoryURL: URL? = nil) {
        self.sessionsDirectoryURL = sessionsDirectoryURL
            ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    func load() throws -> CodexUsageSnapshot {
        let sessionFiles = sessionFileURLsByRecency()
        guard !sessionFiles.isEmpty else {
            throw CodexUsageError.noSessionData
        }

        var lastParseError: CodexUsageError?

        for fileURL in sessionFiles {
            let data = try Data(contentsOf: fileURL)
            guard let text = String(data: data, encoding: .utf8) else {
                lastParseError = .parseFailed("Could not read Codex session data.")
                continue
            }

            do {
                return try parse(text)
            } catch let error as CodexUsageError {
                lastParseError = error
            }
        }

        throw lastParseError ?? CodexUsageError.noTokenCountEvents
    }

    func parse(_ text: String) throws -> CodexUsageSnapshot {
        let decoder = JSONDecoder()
        var latestEvent: CodexTokenCountEvent?

        for line in text.split(whereSeparator: \.isNewline) {
            guard let data = line.data(using: .utf8),
                  let envelope = try? decoder.decode(CodexSessionEnvelope.self, from: data),
                  envelope.type == "event_msg",
                  let payload = envelope.payload,
                  payload.type == "token_count",
                  let rateLimits = payload.rateLimits else {
                continue
            }

            latestEvent = CodexTokenCountEvent(timestamp: envelope.timestamp, rateLimits: rateLimits)
        }

        guard let latestEvent else {
            throw CodexUsageError.noTokenCountEvents
        }

        let metrics = [
            makeMetric(
                id: "primary",
                title: title(for: latestEvent.rateLimits.primary, fallback: "Primary window"),
                limit: latestEvent.rateLimits.primary
            ),
            latestEvent.rateLimits.secondary.map {
                makeMetric(
                    id: "secondary",
                    title: title(for: $0, fallback: "Secondary window"),
                    limit: $0
                )
            },
        ].compactMap { $0 }

        guard let primaryMetric = metrics.first else {
            throw CodexUsageError.parseFailed("Codex usage data did not include a primary rate limit window.")
        }

        let secondaryMetric = metrics.dropFirst().first
        let planType = latestEvent.rateLimits.planType?.trimmingCharacters(in: .whitespacesAndNewlines)

        return CodexUsageSnapshot(
            primaryPercentUsed: primaryMetric.percentUsed,
            primaryPercentRemaining: primaryMetric.percentRemaining,
            primaryResetText: primaryMetric.resetText,
            secondaryPercentUsed: secondaryMetric?.percentUsed,
            secondaryPercentRemaining: secondaryMetric?.percentRemaining,
            secondaryResetText: secondaryMetric?.resetText,
            accountLabel: planType.flatMap { $0.isEmpty ? nil : "Codex plan: \($0.capitalized)" },
            metrics: metrics
        )
    }

    private func sessionFileURLsByRecency() -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsDirectoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let candidates = enumerator.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "jsonl" }

        return candidates.sorted {
            let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhs > rhs
        }
    }

    private func makeMetric(id: String, title: String, limit: CodexRateLimitWindow) -> CodexUsageMetric {
        let percentUsed = max(0, min(100, Int(limit.usedPercent.rounded())))
        return CodexUsageMetric(
            id: id,
            title: title,
            percentUsed: percentUsed,
            percentRemaining: max(0, min(100, 100 - percentUsed)),
            resetText: resetText(forUnixTimestamp: limit.resetsAt)
        )
    }

    private func title(for limit: CodexRateLimitWindow, fallback: String) -> String {
        switch limit.windowMinutes {
        case 300:
            return "Primary window (5h)"
        case 10080:
            return "Weekly window (7d)"
        default:
            return "\(fallback) (\(windowLabel(forMinutes: limit.windowMinutes)))"
        }
    }

    private func windowLabel(forMinutes minutes: Int) -> String {
        if minutes % 1440 == 0 {
            return "\(minutes / 1440)d"
        }
        if minutes % 60 == 0 {
            return "\(minutes / 60)h"
        }
        return "\(minutes)m"
    }

    private func resetText(forUnixTimestamp timestamp: Int?) -> String? {
        guard let timestamp else {
            return nil
        }

        let resetDate = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let formatter = DateFormatter()
        formatter.locale = .current

        if Calendar.current.isDateInToday(resetDate) {
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            return "Resets today at \(formatter.string(from: resetDate))"
        }

        if Calendar.current.isDateInTomorrow(resetDate) {
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            return "Resets tomorrow at \(formatter.string(from: resetDate))"
        }

        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Resets \(formatter.string(from: resetDate))"
    }
}

private struct CodexSessionEnvelope: Decodable {
    let timestamp: String?
    let type: String
    let payload: CodexSessionPayload?
}

private struct CodexSessionPayload: Decodable {
    let type: String
    let rateLimits: CodexRateLimits?

    enum CodingKeys: String, CodingKey {
        case type
        case rateLimits = "rate_limits"
    }
}

private struct CodexTokenCountEvent {
    let timestamp: String?
    let rateLimits: CodexRateLimits
}

private struct CodexRateLimits: Decodable {
    let primary: CodexRateLimitWindow
    let secondary: CodexRateLimitWindow?
    let planType: String?

    enum CodingKeys: String, CodingKey {
        case primary
        case secondary
        case planType = "plan_type"
    }
}

private struct CodexRateLimitWindow: Decodable {
    let usedPercent: Double
    let windowMinutes: Int
    let resetsAt: Int?

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case windowMinutes = "window_minutes"
        case resetsAt = "resets_at"
    }
}

enum CodexUsageError: LocalizedError {
    case noSessionData
    case noTokenCountEvents
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .noSessionData:
            return "No Codex session files were found. Start a Codex session first."
        case .noTokenCountEvents:
            return "No Codex usage snapshots were found yet. Keep a Codex session open for a moment and try again."
        case let .parseFailed(message):
            return message
        }
    }
}
