import Foundation
import WiettyCore
@testable import Wietty

/// Subscribing to one kind of `StoreEvent` at a time.
///
/// The store used to carry four optional closures and a test set the one it cared
/// about. It carries one channel now, and without these a dozen tests would each
/// open a `switch` over four cases to ignore three of them. The assertions in those
/// tests are unchanged; only the line that starts listening is.
@MainActor
extension StoreEventSink {
    @discardableResult
    func onBell(_ handler: @escaping (Project, TerminalRef) -> Void) -> UUID {
        subscribe { if case let .bell(project, ref) = $0 { handler(project, ref) } }
    }

    @discardableResult
    func onNotification(_ handler: @escaping (Project, TerminalRef, String, String) -> Void) -> UUID {
        subscribe {
            if case let .notification(project, ref, title, body) = $0 {
                handler(project, ref, title, body)
            }
        }
    }

    @discardableResult
    func onProgramStatus(_ handler: @escaping (Project, TerminalRef, ProgramStatusRecord) -> Void) -> UUID {
        subscribe {
            if case let .programStatus(project, ref, record) = $0 { handler(project, ref, record) }
        }
    }

    @discardableResult
    func onAttentionCleared(_ handler: @escaping (Set<UUID>) -> Void) -> UUID {
        subscribe { if case let .attentionCleared(ids) = $0 { handler(ids) } }
    }
}
