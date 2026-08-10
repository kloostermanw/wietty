import Foundation

/// Which sessions are live, asked once per attach so a viewer is never registered
/// for a session that cannot produce a byte.
///
/// Three cases, not two, and the third is the reason this type exists. A query
/// that merely failed must never be read as an absence: acting on it would end a
/// viewer watching a terminal that is perfectly fine.
///
/// Answered from the service's own terminal registry, where the question cannot
/// fail at all. The failing case is kept because the protocol is what a viewer
/// reasons about, and a viewer must not be ended by a query that merely failed.
enum SessionCensus: Equatable, Sendable {
    /// The session ids that are live. An id absent from this set is confirmed
    /// gone.
    case sessions(Set<String>)
    /// There is no server at all, so nothing is streamable.
    case noServer
    /// The query failed. Never act on this.
    case unknown
}
