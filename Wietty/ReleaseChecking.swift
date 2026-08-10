import Foundation

/// Errors surfaced by the update pipeline.
enum UpdateError: LocalizedError {
    case badResponse(Int)

    var errorDescription: String? {
        switch self {
        case let .badResponse(code):
            return "GitHub returned an unexpected response (HTTP \(code))."
        }
    }
}

/// Fetches the latest published release. Abstracted so tests can stub it.
protocol ReleaseChecking: Sendable {
    func latestRelease() async throws -> GitHubRelease
}

/// Queries the hardcoded Wietty repo's latest release, unauthenticated.
struct GitHubReleaseService: ReleaseChecking {
    private let owner = "kloostermanw"
    private let repo = "wietty"
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func latestRelease() async throws -> GitHubRelease {
        let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.badResponse((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }
}
