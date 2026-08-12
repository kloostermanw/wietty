import Foundation

/// Which terminal a bell notification is about, and therefore what tapping it
/// should show.
///
/// A local terminal is addressed by its row's id rather than its session id, which
/// is deliberate on both halves of the job: the row id survives a restart that
/// mints a new session, so a tap still reaches the right row, and it is also the
/// key `ProjectStore.attention` uses, so withdrawing a notification when the row
/// is visited needs no lookup that a removed row could fail.
///
/// A remote one is addressed the same way the pane addresses it, connection
/// included, because two Macs routinely hand out the same session id.
enum BellTarget: Equatable, Hashable {
    case local(refId: UUID)
    case remote(RemoteSessionRef)

    /// The notification's identifier, stable per target so a second bell from one
    /// terminal replaces its notification instead of stacking another copy.
    var notificationIdentifier: String {
        switch self {
        case .local(let refId):
            return "bell.local.\(refId.uuidString)"
        case .remote(let session):
            return "bell.remote.\(session.connectionId.uuidString).\(session.sessionId)"
        }
    }

    // MARK: - Carried in the notification

    private enum Key {
        static let kind = "wietty.bell.kind"
        static let ref = "wietty.bell.ref"
        static let connection = "wietty.bell.connection"
        static let session = "wietty.bell.session"
    }

    /// Everything needed to route a tap, as strings.
    ///
    /// A notification's `userInfo` is handed back by the system after an app
    /// relaunch, so what goes in has to survive being written to disk and read by a
    /// later build. Strings and nothing else, for that reason.
    var userInfo: [String: String] {
        switch self {
        case .local(let refId):
            return [Key.kind: "local", Key.ref: refId.uuidString]
        case .remote(let session):
            return [Key.kind: "remote",
                    Key.connection: session.connectionId.uuidString,
                    Key.session: session.sessionId]
        }
    }

    /// The reverse, and nil for anything that does not decode: a notification left
    /// over from an older build, or one belonging to some other feature entirely.
    /// Nil has to mean "ignore this tap", never a crash and never a wrong target.
    init?(userInfo: [AnyHashable: Any]) {
        switch userInfo[Key.kind] as? String {
        case "local":
            guard let raw = userInfo[Key.ref] as? String, let id = UUID(uuidString: raw) else { return nil }
            self = .local(refId: id)
        case "remote":
            guard let rawConnection = userInfo[Key.connection] as? String,
                  let connectionId = UUID(uuidString: rawConnection),
                  let sessionId = userInfo[Key.session] as? String,
                  !sessionId.isEmpty else { return nil }
            self = .remote(RemoteSessionRef(connectionId: connectionId, sessionId: sessionId))
        default:
            return nil
        }
    }
}

/// One notification from a terminal, ready to hand to the notification centre.
/// Either a bell, which carries only that it rang, or a message a process sent
/// with `OSC 9` or `OSC 777`.
///
/// Built here rather than at the call site so what the banner says is asserted in
/// tests instead of only being visible when something rings.
struct BellNotification: Equatable {
    let target: BellTarget
    let title: String
    let subtitle: String
    let body: String
    /// What it plays, from `ProjectStore.bellSound`. Carried on the value rather
    /// than read inside the sink, so the sink stays the untestable part and the
    /// preference reaching a banner is something a test can see.
    let sound: BellSound

    var identifier: String { target.notificationIdentifier }

    /// macOS puts the app's own name above the banner, so the title does not repeat
    /// it and instead says which terminal of which workspace rang, which is the
    /// thing that tells two agents apart.
    static func local(workspace: String, label: String, refId: UUID,
                      sound: BellSound = .systemDefault) -> BellNotification {
        BellNotification(target: .local(refId: refId),
                         title: "\(workspace) / \(label)",
                         subtitle: "",
                         body: Self.body,
                         sound: sound)
    }

    /// A notification a process asked for, with the words it supplied.
    ///
    /// The process's own title goes on top, because it is the thing it wanted read,
    /// and the terminal it came from goes underneath, because with two agents
    /// running "Waiting for input" says nothing about which one. A process that sent
    /// no title (`OSC 9;text`) leaves nothing to put on top, so the terminal moves up
    /// into the title and the subtitle is empty rather than blank: an empty subtitle
    /// closes the gap, a repeated one wastes the line.
    static func sent(workspace: String, label: String, refId: UUID,
                     title: String, body: String,
                     sound: BellSound = .systemDefault) -> BellNotification {
        let terminal = "\(workspace) / \(label)"
        return BellNotification(target: .local(refId: refId),
                                title: title.isEmpty ? terminal : title,
                                subtitle: title.isEmpty ? "" : terminal,
                                body: body,
                                sound: sound)
    }

    /// The connection's name goes in the subtitle, because a remote bell is
    /// otherwise indistinguishable from a local one and "which Mac" is the first
    /// thing you need to know.
    static func remote(connection: String, workspace: String, label: String,
                       session: RemoteSessionRef,
                       sound: BellSound = .systemDefault) -> BellNotification {
        BellNotification(target: .remote(session),
                         title: "\(workspace) / \(label)",
                         subtitle: connection,
                         body: Self.body,
                         sound: sound)
    }

    /// The one the Test button in Settings posts, so the whole path (permission,
    /// centre, banner, sound) can be checked without waiting for a real bell.
    ///
    /// Its target is a random row id, which matches no row: tapping it reopens the
    /// window and finds nothing to activate, which is the right amount of nothing
    /// for a test banner, and a fresh id per press means two presses do not replace
    /// each other.
    static func test(sound: BellSound = .systemDefault) -> BellNotification {
        BellNotification(target: .local(refId: UUID()),
                         title: "Wietty",
                         subtitle: "",
                         body: "This is what a notification from a terminal looks like.",
                         sound: sound)
    }

    /// Deliberately plain. All a bell carries is that it rang; anything more
    /// specific ("waiting for input") would be a guess about a program we only
    /// received one byte from.
    private static let body = "Rang the bell."
}

/// Whether a bell is worth interrupting for.
///
/// Separate from the notification itself so the rule can be stated once and
/// asserted, rather than living inline in a closure in `ContentView`.
enum BellAlert {
    /// Nothing is posted about a terminal the user is already looking at, which
    /// means this app is frontmost and its pane is showing that exact terminal.
    ///
    /// Answerable because the terminal is inside this window: what is on screen is
    /// a fact the app owns.
    static func shouldPost(appIsFrontmost: Bool, terminalIsOnScreen: Bool) -> Bool {
        !(appIsFrontmost && terminalIsOnScreen)
    }
}
