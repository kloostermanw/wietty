import Foundation

/// A parsed `GET /tests/wait` request: the test ids to wait on and how long to hold
/// the request open. Kept free of HTTP and store types so the query rules are
/// unit-testable on their own; `MCPToolRouter.waitForTests` resolves the ids and
/// `MCPServerHost` serves the route.
struct TestWaitRequest: Equatable {
    static let defaultTimeoutSeconds = 600
    static let maxTimeoutSeconds = 3600

    /// Distinct, well-formed test handles, in the order first given.
    let ids: [String]
    let timeoutSeconds: Int

    /// Reads the repeated `id` parameter and the optional `timeout` (whole seconds,
    /// clamped to `maxTimeoutSeconds`). Unrelated parameters are ignored. An id must
    /// be a test handle: a process never finishes the way a test does, so waiting on
    /// one is rejected as a bad request rather than reported as unknown.
    static func parse(_ query: [(name: String, value: String)]) throws(TestWaitError) -> TestWaitRequest {
        var ids: [String] = []
        var timeout = defaultTimeoutSeconds
        for (name, value) in query {
            switch name {
            case "id":
                guard let parsed = ManagedProcessID.parse(value) else { throw .invalidId(value) }
                guard parsed.isTest else { throw .notATest(value) }
                if !ids.contains(value) { ids.append(value) }
            case "timeout":
                guard let seconds = Int(value), seconds >= 0 else { throw .invalidTimeout(value) }
                timeout = min(seconds, maxTimeoutSeconds)
            default:
                continue
            }
        }
        guard !ids.isEmpty else { throw .missingId }
        return TestWaitRequest(ids: ids, timeoutSeconds: timeout)
    }
}

/// A request the wait endpoint refuses before looking anything up. Every case is a
/// client mistake, so every case is a 400.
enum TestWaitError: LocalizedError, Equatable {
    case missingId
    case invalidId(String)
    case notATest(String)
    case invalidTimeout(String)

    var httpStatus: Int { 400 }

    var errorDescription: String? {
        switch self {
        case .missingId: return "Missing required query parameter: id."
        case let .invalidId(id): return "id is not a managed process handle: \(id)."
        case let .notATest(id): return "id is not a test: \(id). Only tests can be waited on."
        case let .invalidTimeout(raw): return "timeout must be a whole number of seconds, got \"\(raw)\"."
        }
    }
}

/// How a wait ended, ranked so one status code speaks for the whole set. A timeout
/// wins (something is still running, so no verdict exists yet), then a test that
/// never ran (the wait is over but that test has no result), then a failure.
enum TestWaitOutcome: Equatable {
    case finished
    case failed
    case notStarted
    case timedOut

    /// `settled` is whether every test left the in-flight states before the deadline.
    init(states: [ProcessState], settled: Bool) {
        if !settled {
            self = .timedOut
        } else if states.contains(.idle) {
            self = .notStarted
        } else if states.contains(where: { if case .failed = $0 { return true } else { return false } }) {
            self = .failed
        } else {
            self = .finished
        }
    }

    /// Chosen so `curl --fail-with-body` exits non-zero for every outcome but a pass.
    var httpStatus: Int {
        switch self {
        case .finished: return 200
        case .failed: return 422
        case .notStarted: return 409
        case .timedOut: return 504
        }
    }

    /// Every test reached `finished` or `failed`.
    var done: Bool { self == .finished || self == .failed }
}
