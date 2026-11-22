import Foundation

/// Something that contributes lines to `~/.config/wietty/config`.
///
/// The settings in that file belong to two owners now: the store keeps the
/// workspaces and everything the server side needs, and `UIPreferences` keeps the
/// four that are this Mac's view of them. Both still write one file.
@MainActor
package protocol SettingsPairSource: AnyObject {
    /// This source's lines, in the order they should appear.
    var settingsPairs: [(key: String, value: String)] { get }

    /// The scalar keys this source is responsible for, emitted or not.
    ///
    /// Omitting a key it owns is how a setting back at its default loses its line,
    /// so the writer has to tell that apart from a key no registered source speaks
    /// for at all. See `SettingsWriter.preservingUnowned`.
    var ownedKeys: Set<String> { get }
}

/// What the config file held at launch, and whether that launch migrated from the
/// old `UserDefaults` keys.
///
/// `ProjectStore` reads the file first and, on a migrating launch, removes those old
/// keys once it has seeded the file. A second settings source reading afterwards
/// would find both the lines and the defaults gone, so the store captures this during
/// its own init and hands it over instead.
package struct SettingsLaunch {
    package let values: [String: String]
    package let migrating: Bool

    package init(values: [String: String], migrating: Bool) {
        self.values = values
        self.migrating = migrating
    }
}

/// The one writer of `~/.config/wietty/config`.
///
/// There is one because the file must not move. `WiettyConfigFile.write` drops
/// every managed line and appends the pairs it is handed at the end, so two writers
/// with disjoint keys would still be correct on content while shuffling the blocks
/// against each other on every write. A user diffing their own config would see
/// churn that means nothing. One writer, handed every source's pairs in a fixed
/// order, writes the same bytes the single `persistSettings` wrote before the split.
///
/// The cost is that the sources are not independently persistable: `UIPreferences`
/// cannot save without the store, because saving means rewriting the whole managed
/// set. That is the right price while both live in one process. Phase 5 gives the
/// frontend a file of its own and the coupling goes with it.
@MainActor
package final class SettingsWriter {
    private let file: WiettyConfigFile
    private var sources: [any SettingsPairSource] = []

    /// Whether writing is allowed at all.
    ///
    /// False after a launch that could not read the file, so a corrupt or
    /// half-written config is never overwritten with defaults. It lives here rather
    /// than on a source because it is a property of the file: one unreadable file
    /// has to suppress one write, not one per source.
    package var isPersistable = true

    /// What went wrong with the last write, or nil. Read by whoever can still show
    /// the user a message about it.
    package private(set) var lastError: String?

    package init(file: WiettyConfigFile) {
        self.file = file
    }

    /// Registers a source. Order matters and is the order lines appear in the file,
    /// so this is called in the order the single writer used to emit them.
    package func add(_ source: any SettingsPairSource) {
        sources.append(source)
    }

    /// Keeps the scalar settings that no registered source speaks for.
    ///
    /// `WiettyConfigFile.write` removes every managed key the pairs do not mention,
    /// which is what lets a setting back at its default drop its line. The hazard is
    /// a source that is not registered yet: the file holds its keys, nothing emits
    /// them, and the write deletes a user's settings. That is not hypothetical, it
    /// happened to the sidebar colours while this split was being made.
    ///
    /// So a managed scalar that no registered source owns keeps the value the file
    /// already had. A key its owner deliberately left out is still dropped, which is
    /// how clearing a colour removes its line. Only scalars: the list prefixes must
    /// prune, because a group or an agent that was deleted has to lose its lines, and
    /// the source that owns a list always emits the whole list or none of it.
    static func preservingUnowned(_ pairs: [(key: String, value: String)],
                                  owned: Set<String>,
                                  existing: [String: String]?) -> [(key: String, value: String)] {
        guard let existing else { return pairs }
        let kept = SettingsKeys.scalars
            .subtracting(owned)
            .subtracting(pairs.map(\.key))
            .compactMap { key in existing[key].map { (key: key, value: $0) } }
        return pairs + kept
    }

    /// Puts the collected pairs into the file's declared order.
    ///
    /// Stable, so entries sharing a prefix keep the order their source emitted them
    /// in, which is what makes `agent.0` come before `agent.1` and a workspace's rows
    /// stay with it. See `SettingsKeys.fileOrder` for why the order is declared
    /// rather than left to whichever source happens to be registered first.
    static func ordered(_ pairs: [(key: String, value: String)]) -> [(key: String, value: String)] {
        func rank(_ key: String) -> Int {
            for (i, entry) in SettingsKeys.fileOrder.enumerated() {
                if entry.hasSuffix(".") ? key.hasPrefix(entry) : key == entry { return i }
            }
            return SettingsKeys.fileOrder.count
        }
        return pairs.enumerated()
            .sorted { ($0.element.key == $1.element.key) ? $0.offset < $1.offset
                      : (rank($0.element.key), $0.offset) < (rank($1.element.key), $1.offset) }
            .map(\.element)
    }

    /// Rewrites the managed part of the file from every source.
    ///
    /// Returns whether the write happened, which the first launch migration uses to
    /// decide whether it is safe to drop the old `UserDefaults` keys.
    @discardableResult
    package func write() -> Bool {
        guard isPersistable else { return false }
        let owned = sources.reduce(into: Set<String>()) { $0.formUnion($1.ownedKeys) }
        let pairs = Self.ordered(Self.preservingUnowned(sources.flatMap(\.settingsPairs),
                                                        owned: owned,
                                                        existing: try? file.read()))
        do {
            try file.write(pairs, managedKeys: SettingsKeys.scalars,
                           managedPrefixes: SettingsKeys.prefixes)
            lastError = nil
            return true
        } catch {
            lastError = "Could not save settings: \(error.localizedDescription)"
            return false
        }
    }
}
