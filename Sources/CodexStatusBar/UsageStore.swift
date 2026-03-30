import AppKit
import Foundation
import SwiftUI

@MainActor
final class UsageStore: ObservableObject {
    enum RefreshState {
        case enabled
        case disabled
    }

    @Published private(set) var primaryPercent = 0
    @Published private(set) var primaryPercentRemaining = 0
    @Published private(set) var primaryResetText: String?
    @Published private(set) var secondaryPercent = 0
    @Published private(set) var secondaryPercentRemaining = 0
    @Published private(set) var secondaryResetText: String?
    @Published private(set) var accountLabel: String?
    @Published private(set) var metrics: [CodexUsageMetric] = []
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var lastUpdatedText = "Never"
    @Published private(set) var isReloading = false
    @Published private(set) var isCheckingForUpdates = false
    @Published private(set) var updateStatusMessage: String?
    @Published private(set) var refreshState: RefreshState = .enabled

    let sessionsDirectoryPath: String

    var menuBarTitle: String {
        switch refreshState {
        case .enabled:
            "\(primaryPercent) - \(secondaryPercent)"
        case .disabled:
            "Codex"
        }
    }

    private let provider: CodexUsageProvider
    private let updater: AppUpdater
    private var refreshTask: Task<Void, Never>?
    private var activeUntil: Date?

    private static let refreshInterval: Duration = .seconds(240)
    private static let activeWindow: Duration = .seconds(3600)

    init(provider: CodexUsageProvider, updater: AppUpdater = AppUpdater()) {
        self.provider = provider
        self.updater = updater
        self.sessionsDirectoryPath = provider.sessionsDirectoryURL.path

        enableRefreshing(triggerImmediateReload: true)
    }

    deinit {
        refreshTask?.cancel()
    }

    func reload() {
        guard !isReloading else {
            return
        }

        isReloading = true

        Task.detached(priority: .userInitiated) { [provider] in
            do {
                let snapshot = try provider.load()
                await MainActor.run {
                    self.primaryPercent = snapshot.primaryPercentUsed
                    self.primaryPercentRemaining = snapshot.primaryPercentRemaining
                    self.primaryResetText = snapshot.primaryResetText
                    self.secondaryPercent = snapshot.secondaryPercentUsed ?? 0
                    self.secondaryPercentRemaining = snapshot.secondaryPercentRemaining ?? 0
                    self.secondaryResetText = snapshot.secondaryResetText
                    self.accountLabel = snapshot.accountLabel
                    self.metrics = snapshot.metrics
                    self.lastUpdatedText = Self.timestampFormatter.string(from: Date())
                    self.lastErrorMessage = nil
                    self.isReloading = false
                }
            } catch {
                await MainActor.run {
                    self.lastErrorMessage = error.localizedDescription
                    self.primaryPercent = 0
                    self.primaryPercentRemaining = 0
                    self.primaryResetText = nil
                    self.secondaryPercent = 0
                    self.secondaryPercentRemaining = 0
                    self.secondaryResetText = nil
                    self.accountLabel = nil
                    self.metrics = []
                    self.lastUpdatedText = Self.timestampFormatter.string(from: Date())
                    self.isReloading = false
                }
            }
        }
    }

    func revealSessionsDirectory() {
        NSWorkspace.shared.activateFileViewerSelecting([provider.sessionsDirectoryURL])
    }

    func handleMenuOpened() {
        guard refreshState == .disabled else {
            return
        }

        enableRefreshing(triggerImmediateReload: true)
    }

    func disable() {
        disableRefreshing()
    }

    func checkForUpdates() {
        guard !isCheckingForUpdates else {
            return
        }

        isCheckingForUpdates = true
        updateStatusMessage = "Checking for updates..."

        Task { [updater] in
            do {
                let result = try await updater.checkForUpdatesAndInstallIfNeeded()
                await MainActor.run {
                    switch result {
                    case .upToDate(let currentVersion):
                        self.updateStatusMessage = "You're up to date (\(currentVersion))."
                    case .installing(let version):
                        self.updateStatusMessage = "Installing v\(version)..."
                    case .openedReleasePage(let version):
                        self.updateStatusMessage = "Opened GitHub release v\(version). Install it manually from there."
                    }
                    self.isCheckingForUpdates = false
                }
            } catch {
                await MainActor.run {
                    self.updateStatusMessage = error.localizedDescription
                    self.isCheckingForUpdates = false
                }
            }
        }
    }

    private func enableRefreshing(triggerImmediateReload: Bool) {
        refreshState = .enabled
        activeUntil = Date().addingTimeInterval(Self.activeWindow.timeInterval)

        refreshTask?.cancel()

        if triggerImmediateReload {
            reload()
        }

        startRefreshTask()
    }

    private func disableRefreshing() {
        refreshState = .disabled
        activeUntil = nil
        refreshTask?.cancel()
        refreshTask = nil
    }

    private func startRefreshTask() {
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else {
                    break
                }

                guard await MainActor.run(body: { self.activeUntil != nil }) else {
                    break
                }

                try? await Task.sleep(for: Self.refreshInterval)

                guard !Task.isCancelled else {
                    break
                }

                await MainActor.run {
                    guard let activeUntil = self.activeUntil else {
                        return
                    }

                    if Date() >= activeUntil {
                        self.disableRefreshing()
                        return
                    }

                    self.reload()
                }
            }
        }
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}

private extension Duration {
    var timeInterval: TimeInterval {
        TimeInterval(components.seconds) + (TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000)
    }
}
