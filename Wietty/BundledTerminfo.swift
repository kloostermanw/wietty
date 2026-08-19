import Foundation

/// The `xterm-ghostty` terminfo the app ships, and the `TERM` and
/// `TERMINFO_DIRS` a spawned child needs to use it.
///
/// Wietty renders with libghostty, so the truthful `TERM` is `xterm-ghostty`.
/// That name is only usable if the terminfo entry exists in a database the child
/// can read, and the usual source of it is Ghostty.app, which this app
/// deliberately does not require. So the app compiles a small entry into its
/// Resources at build time (`project.yml`, `tic -x`) and points children at it
/// with `TERMINFO_DIRS`. When the resource is absent (a build that did not run
/// the compile step), the safe answer is `xterm-256color`, which every macOS
/// terminfo database carries, and no `TERMINFO_DIRS` is added. A `TERM` naming
/// an entry the database does not hold breaks every ncurses program, which is
/// the whole reason the value is resolved rather than hard coded.
///
/// The name matters past rendering. An agent decides whether to emit an `OSC 9`
/// desktop notification by recognising the terminal, and several tools (Claude
/// Code among them) key that on `TERM == "xterm-ghostty"` exactly. Under the
/// `xterm-256color` fallback they see an unknown terminal and stay silent, so
/// the bundled entry is what makes an agent's notifications work without the
/// user configuring anything. See `docs/notifications.md`.
enum BundledTerminfo {
    /// Resource subdirectory holding the compiled entry.
    private static let resourceName = "terminfo"

    /// The layouts `tic` may write the entry under, keyed by the first letter of
    /// the name: a hex directory (`78` is `x`) or a single letter directory.
    /// Either resolves at runtime; we only need to confirm the entry is present.
    private static let entryPaths = ["78/xterm-ghostty", "x/xterm-ghostty"]

    /// The bundled terminfo directory, or nil when this build did not produce a
    /// compiled `xterm-ghostty` under it.
    static let directory: URL? = resolve(in: .main)

    /// The `TERM` to advertise to a child.
    static var term: String { term(bundled: directory != nil) }

    /// `xterm-ghostty` when the entry is bundled, else the fallback every macOS
    /// terminfo database carries. Split from `term` so the choice is testable
    /// without a built app bundle.
    static func term(bundled: Bool) -> String {
        bundled ? "xterm-ghostty" : "xterm-256color"
    }

    /// `TERMINFO_DIRS` for a child, prepending the bundled directory to whatever
    /// the child would otherwise inherit so every other `TERM` still resolves.
    /// Nil when there is nothing bundled to point at, which leaves the caller's
    /// existing value untouched.
    static func terminfoDirs(inheriting existing: String?) -> String? {
        terminfoDirs(directory: directory, inheriting: existing)
    }

    /// The composition rule, parameterised on the directory so it is testable
    /// without the bundle.
    static func terminfoDirs(directory: URL?, inheriting existing: String?) -> String? {
        guard let directory else { return nil }
        if let existing, !existing.isEmpty { return "\(directory.path):\(existing)" }
        // A trailing separator keeps the compiled in default databases on the
        // search path, so the bundled entry adds to them rather than hides them.
        return "\(directory.path):"
    }

    /// Locates the bundled directory and confirms the compiled entry is in it.
    /// Parameterised on the bundle and the existence check so the layout logic
    /// is testable without a built app bundle.
    static func resolve(in bundle: Bundle,
                        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> URL? {
        guard let dir = bundle.url(forResource: resourceName, withExtension: nil),
              hasEntry(in: dir, fileExists: fileExists) else { return nil }
        return dir
    }

    /// Whether `directory` holds a compiled `xterm-ghostty` in either layout.
    static func hasEntry(in directory: URL,
                         fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Bool {
        entryPaths.contains { fileExists(directory.appendingPathComponent($0).path) }
    }
}
