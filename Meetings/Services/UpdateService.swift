import Foundation
import Observation
import os

struct ReleaseVersion: Comparable {
    let components: [Int]

    init?(_ text: String) {
        let value = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let number = Int(part) else { return nil }
            numbers.append(number)
        }
        components = numbers + Array(repeating: 0, count: 3 - numbers.count)
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.components.lexicographicallyPrecedes(rhs.components)
    }
}

private struct GitHubRelease: Decodable {
    let tag_name: String
    let draft: Bool
    let prerelease: Bool
}

private enum UpdateError: LocalizedError {
    case invalidResponse
    case server(Int)
    case invalidVersion

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "GitHub sent a release the app couldn't read."
        case .server(let code): "GitHub returned HTTP \(code). Try again later."
        case .invalidVersion: "The app or release version isn't in the expected format (for example, 1.2.0)."
        }
    }
}

@MainActor
@Observable
final class UpdateService {
    nonisolated static let automaticKey = "automaticallyCheckForUpdates"
    static let releasesURL = URL(string: "https://github.com/rb81/meetings/releases/latest")!
    private static let endpoint = URL(string: "https://api.github.com/repos/rb81/meetings/releases/latest")!
    private static let lastAttemptKey = "releaseLastAttempt"
    private static let dismissedKey = "dismissedReleaseTag"
    private static let latestKey = "availableReleaseTag"
    private static let interval: TimeInterval = 86_400

    typealias Fetch = @MainActor (URLRequest) async throws -> (Data, URLResponse)

    private(set) var isChecking = false
    private(set) var status = "Not checked yet."
    private(set) var latestVersion: String?
    private var dismissedTag: String?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let currentVersion: String
    @ObservationIgnored private let fetch: Fetch
    @ObservationIgnored private let log = Logger(subsystem: "com.rakan.Meetings", category: "updates")

    var availableVersion: String? {
        latestVersion == dismissedTag ? nil : latestVersion
    }

    init(
        defaults: UserDefaults = .standard,
        currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
        fetch: @escaping Fetch = { request in try await URLSession.shared.data(for: request) }
    ) {
        self.defaults = defaults
        self.currentVersion = currentVersion
        self.fetch = fetch
        dismissedTag = defaults.string(forKey: Self.dismissedKey)
        if let tag = defaults.string(forKey: Self.latestKey),
           let cached = ReleaseVersion(tag), let installed = ReleaseVersion(currentVersion),
           cached > installed {
            latestVersion = tag
            status = "Meetings \(tag) is available."
        }
    }

    func dismiss() {
        dismissedTag = latestVersion
        defaults.set(dismissedTag, forKey: Self.dismissedKey)
    }

    func monitor() async {
        while !Task.isCancelled {
            await check()
            do {
                try await Task.sleep(for: .seconds(3_600))
            } catch {
                return
            }
        }
    }

    func check(force: Bool = false, now: Date = .now) async {
        guard !isChecking, !Task.isCancelled else { return }
        guard !defaults.bool(forKey: NetworkPolicy.offlineKey) else {
            status = "Update checks are paused in offline mode."
            return
        }
        if !force {
            guard defaults.object(forKey: Self.automaticKey) as? Bool ?? true else { return }
            if let last = defaults.object(forKey: Self.lastAttemptKey) as? Date,
               now.timeIntervalSince(last) < Self.interval {
                return
            }
        }

        isChecking = true
        status = "Checking GitHub Releases…"
        defaults.set(now, forKey: Self.lastAttemptKey)
        defer { isChecking = false }

        do {
            guard let installed = ReleaseVersion(currentVersion) else { throw UpdateError.invalidVersion }
            var request = URLRequest(url: Self.endpoint)
            request.timeoutInterval = 20
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            request.setValue("Meetings-update-check", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await fetch(request)
            try Task.checkCancellation()
            guard !defaults.bool(forKey: NetworkPolicy.offlineKey) else {
                status = "Update checks are paused in offline mode."
                defaults.removeObject(forKey: Self.lastAttemptKey)
                return
            }
            guard force || (defaults.object(forKey: Self.automaticKey) as? Bool ?? true) else {
                status = "Automatic update checks are off."
                defaults.removeObject(forKey: Self.lastAttemptKey)
                return
            }
            guard let response = response as? HTTPURLResponse else { throw UpdateError.invalidResponse }
            if response.statusCode == 404 {
                latestVersion = nil
                defaults.removeObject(forKey: Self.latestKey)
                status = "No public release is available yet."
                return
            }
            guard response.statusCode == 200 else { throw UpdateError.server(response.statusCode) }
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            guard !release.draft, !release.prerelease else { throw UpdateError.invalidResponse }
            guard let version = ReleaseVersion(release.tag_name) else { throw UpdateError.invalidVersion }
            latestVersion = version > installed ? release.tag_name : nil
            defaults.set(latestVersion, forKey: Self.latestKey)
            status = latestVersion.map { "Meetings \($0) is available." } ?? "You're up to date."
        } catch is CancellationError {
            status = "Update check cancelled."
            defaults.removeObject(forKey: Self.lastAttemptKey)
        } catch let error as URLError where error.code == .cancelled {
            status = "Update check cancelled."
            defaults.removeObject(forKey: Self.lastAttemptKey)
        } catch {
            status = "Couldn't check for updates. \(error.localizedDescription)"
            log.error("Release check failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
