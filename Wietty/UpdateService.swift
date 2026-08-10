import Foundation
import Observation
import AppKit
import os

@MainActor
@Observable
final class UpdateService {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(GitHubRelease)
        case downloading
        case downloaded(URL)
        case failed(message: String)
    }

    private(set) var state: State = .idle

    private let checker: ReleaseChecking
    private let defaults: UserDefaults
    private let currentVersion: AppVersion
    private let throttle: TimeInterval
    private let now: () -> Date

    private let lastCheckKey = "UpdateService.lastCheck"
    private let skippedTagKey = "UpdateService.skippedTag"

    private static let logger = Logger(subsystem: "eu.kloosterman.wietty", category: "updates")

    init(
        checker: ReleaseChecking = GitHubReleaseService(),
        defaults: UserDefaults = .standard,
        currentVersion: AppVersion = .current,
        throttle: TimeInterval = 2 * 60 * 60,
        now: @escaping () -> Date = Date.init
    ) {
        self.checker = checker
        self.defaults = defaults
        self.currentVersion = currentVersion
        self.throttle = throttle
        self.now = now
    }

    func checkForUpdates(userInitiated: Bool) async {
        if !userInitiated {
            switch state {
            case .available, .downloading, .downloaded:
                return
            default:
                break
            }
        }

        if !userInitiated,
           let last = defaults.object(forKey: lastCheckKey) as? Date,
           now().timeIntervalSince(last) < throttle {
            return
        }

        state = .checking
        do {
            let release = try await checker.latestRelease()
            defaults.set(now(), forKey: lastCheckKey)
            guard release.version.isNewer(than: currentVersion) else {
                state = userInitiated ? .upToDate : .idle
                return
            }
            if !userInitiated, defaults.string(forKey: skippedTagKey) == release.tagName {
                state = .idle
                return
            }
            state = .available(release)
        } catch {
            if userInitiated {
                state = .failed(message: error.localizedDescription)
            } else {
                Self.logger.error("Background update check failed: \(error.localizedDescription, privacy: .public)")
                state = .idle
            }
        }
    }

    func download(_ release: GitHubRelease) async {
        guard let asset = release.dmgAsset else {
            state = .failed(message: "The latest release has no .dmg download.")
            return
        }
        state = .downloading
        do {
            let (tempURL, _) = try await URLSession.shared.download(from: asset.downloadURL)
            let downloads = try FileManager.default.url(
                for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            )
            let dest = uniqueDestination(in: downloads, fileName: asset.name)
            try FileManager.default.moveItem(at: tempURL, to: dest)
            state = .downloaded(dest)
            NSWorkspace.shared.activateFileViewerSelecting([dest])
        } catch {
            state = .failed(message: error.localizedDescription)
        }
    }

    func skip(_ release: GitHubRelease) {
        defaults.set(release.tagName, forKey: skippedTagKey)
        state = .idle
    }

    func dismiss() {
        if case .downloading = state { return }
        state = .idle
    }

    func runPeriodicChecks() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(throttle))
            await checkForUpdates(userInitiated: false)
        }
    }

    /// Avoids clobbering an existing file by suffixing " (1)", " (2)", etc.
    private func uniqueDestination(in directory: URL, fileName: String) -> URL {
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var candidate = directory.appendingPathComponent(fileName)
        var counter = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            candidate = directory.appendingPathComponent(name)
            counter += 1
        }
        return candidate
    }
}
