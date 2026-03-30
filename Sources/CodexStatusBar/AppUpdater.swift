import AppKit
import Foundation

enum AppUpdateResult: Sendable {
    case upToDate(currentVersion: String)
    case installing(version: String)
    case openedReleasePage(version: String)
}

struct AppUpdater: Sendable {
    let owner: String
    let repository: String

    init(owner: String = "azwandi", repository: String = "codex-status-bar") {
        self.owner = owner
        self.repository = repository
    }

    func checkForUpdatesAndInstallIfNeeded() async throws -> AppUpdateResult {
        let release = try await fetchLatestRelease()
        let currentVersion = currentAppVersion()
        let latestVersion = normalizeVersion(release.tagName)

        guard isVersion(latestVersion, newerThan: currentVersion) else {
            return .upToDate(currentVersion: currentVersion)
        }

        guard let asset = release.assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") }),
              let targetAppURL = installedAppBundleURL() else {
            _ = await MainActor.run {
                NSWorkspace.shared.open(release.htmlURL)
            }
            return .openedReleasePage(version: latestVersion)
        }

        try await downloadAndInstall(asset: asset, targetAppURL: targetAppURL)
        return .installing(version: latestVersion)
    }

    private func fetchLatestRelease() async throws -> Release {
        let url = URL(string: "https://api.github.com/repos/\(owner)/\(repository)/releases")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("CodexStatusBar", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, 200..<300 ~= httpResponse.statusCode else {
            throw UpdaterError.releaseLookupFailed
        }

        do {
            let releases = try JSONDecoder().decode([Release].self, from: data)
            guard let release = releases.first(where: { !$0.isDraft && !$0.isPrerelease }) else {
                throw UpdaterError.releaseLookupFailed
            }
            return release
        } catch {
            throw UpdaterError.releaseLookupFailed
        }
    }

    private func currentAppVersion() -> String {
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              !version.isEmpty else {
            return "0.0.0"
        }

        return normalizeVersion(version)
    }

    private func installedAppBundleURL() -> URL? {
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app" else {
            return nil
        }

        return bundleURL
    }

    private func downloadAndInstall(asset: ReleaseAsset, targetAppURL: URL) async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexStatusBarUpdate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

        let downloadedDMGURL = try await download(asset: asset, into: temporaryDirectory)
        let mountURL = temporaryDirectory.appendingPathComponent("mount", isDirectory: true)
        try FileManager.default.createDirectory(at: mountURL, withIntermediateDirectories: true)

        try runProcess(
            "/usr/bin/hdiutil",
            arguments: ["attach", downloadedDMGURL.path, "-nobrowse", "-quiet", "-mountpoint", mountURL.path]
        )

        let stagedAppURL: URL
        do {
            guard let mountedAppURL = try FileManager.default.contentsOfDirectory(
                at: mountURL,
                includingPropertiesForKeys: nil
            ).first(where: { $0.pathExtension == "app" }) else {
                throw UpdaterError.missingAppInDiskImage
            }

            stagedAppURL = temporaryDirectory.appendingPathComponent("CodexStatusBar.app", isDirectory: true)
            try FileManager.default.copyItem(at: mountedAppURL, to: stagedAppURL)
        } catch {
            try? runProcess("/usr/bin/hdiutil", arguments: ["detach", mountURL.path, "-quiet"])
            throw error
        }

        try runProcess("/usr/bin/hdiutil", arguments: ["detach", mountURL.path, "-quiet"])

        let scriptURL = temporaryDirectory.appendingPathComponent("install-update.sh")
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let script = """
        #!/bin/bash
        set -euo pipefail
        while kill -0 \(currentPID) 2>/dev/null; do
          sleep 1
        done
        rm -rf \(shellQuoted(targetAppURL.path))
        cp -R \(shellQuoted(stagedAppURL.path)) \(shellQuoted(targetAppURL.path))
        xattr -dr com.apple.quarantine \(shellQuoted(targetAppURL.path)) >/dev/null 2>&1 || true
        open \(shellQuoted(targetAppURL.path))
        rm -rf \(shellQuoted(temporaryDirectory.path))
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]
        try process.run()

        await MainActor.run {
            NSApp.terminate(nil)
        }
    }

    private func download(asset: ReleaseAsset, into directory: URL) async throws -> URL {
        var request = URLRequest(url: asset.browserDownloadURL)
        request.setValue("CodexStatusBar", forHTTPHeaderField: "User-Agent")

        let (temporaryURL, response) = try await URLSession.shared.download(for: request)
        guard let httpResponse = response as? HTTPURLResponse, 200..<300 ~= httpResponse.statusCode else {
            throw UpdaterError.downloadFailed
        }

        let destinationURL = directory.appendingPathComponent(asset.name)
        try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
        return destinationURL
    }

    private func runProcess(_ launchPath: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let errorPipe = Pipe()
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorText = String(data: errorData, encoding: .utf8) ?? ""
            throw UpdaterError.processFailed(errorText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func normalizeVersion(_ value: String) -> String {
        value.hasPrefix("v") ? String(value.dropFirst()) : value
    }

    private func isVersion(_ lhs: String, newerThan rhs: String) -> Bool {
        let left = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let right = rhs.split(separator: ".").map { Int($0) ?? 0 }
        let count = max(left.count, right.count)

        for index in 0..<count {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r {
                return l > r
            }
        }

        return false
    }

    private func shellQuoted(_ string: String) -> String {
        "'\(string.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }
}

private struct Release: Decodable, Sendable {
    let tagName: String
    let htmlURL: URL
    let isDraft: Bool
    let isPrerelease: Bool
    let assets: [ReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case isDraft = "draft"
        case isPrerelease = "prerelease"
        case assets
    }
}

private struct ReleaseAsset: Decodable, Sendable {
    let name: String
    let browserDownloadURL: URL

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}

enum UpdaterError: LocalizedError {
    case releaseLookupFailed
    case downloadFailed
    case missingAppInDiskImage
    case processFailed(String)

    var errorDescription: String? {
        switch self {
        case .releaseLookupFailed:
            return "Could not check GitHub for the latest release."
        case .downloadFailed:
            return "Could not download the latest release."
        case .missingAppInDiskImage:
            return "The downloaded update did not contain a macOS app bundle."
        case .processFailed(let message):
            return message.isEmpty ? "The update installer failed." : message
        }
    }
}
