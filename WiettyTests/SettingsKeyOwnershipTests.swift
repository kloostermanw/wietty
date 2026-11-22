import Foundation
import Testing
import WiettyCore
@testable import Wietty

/// Every managed scalar has exactly one owner.
///
/// `SettingsWriter` keeps a managed scalar that no registered source owns, which is
/// what stops a write made before a source has registered from deleting that source's
/// settings. The rule has a cost: a key its owner forgets to claim becomes impossible
/// to clear, because the writer preserves it forever instead of letting an omission
/// mean "back to the default". That failure is silent, so it is asserted here.
///
/// Guards the writer added in the settings split, and lives at the tip of the branch
/// stack rather than in that commit, so five branches are not rewritten underneath it.
@MainActor
@Suite struct SettingsKeyOwnershipTests {

    /// Both sources, wired the way the app wires them.
    private func sources() -> [any SettingsPairSource] {
        let fixture = SettingsFixture(config: WiettyConfigFile.temporary())
        return [fixture.store, fixture.preferences]
    }

    @Test func everyManagedScalarIsOwnedByExactlyOneSource() {
        let owners = sources().map(\.ownedKeys)
        let union = owners.reduce(into: Set<String>()) { $0.formUnion($1) }

        // Nothing unowned: a scalar nobody claims can never be cleared, because the
        // writer would preserve the file's old value on every write.
        #expect(SettingsKeys.scalars.subtracting(union).isEmpty)

        // Nothing claimed that is not managed: a key outside `scalars` is neither
        // written as part of the managed set nor pruned, so claiming it says nothing.
        #expect(union.subtracting(SettingsKeys.scalars).isEmpty)

        // And no scalar owned twice, which would make which source wins depend on
        // registration order.
        for (index, keys) in owners.enumerated() {
            for other in owners[(index + 1)...] {
                #expect(keys.intersection(other).isEmpty)
            }
        }
    }

    /// The rule with teeth: a source may only emit keys it owns.
    ///
    /// Emitting one it does not own is the silent failure this suite exists for. The
    /// writer sees the key in the pairs and writes it, so it looks correct, right up
    /// until the source stops emitting it and the old value is preserved rather than
    /// dropped. Every setting is moved off its default first, so a source that only
    /// emits a key when it is set still emits it here.
    @Test func noSourceEmitsAScalarItDoesNotOwn() {
        let fixture = SettingsFixture(config: WiettyConfigFile.temporary())
        fixture.store.showWorkspaceBadge = true
        fixture.store.notificationSource = .programStatus
        fixture.store.checkIntervals = CheckIntervals(fast: 20, normal: 90, slow: 400)
        fixture.store.remoteEnabled = true
        fixture.store.remotePort = 9100
        fixture.store.mcpPort = 4100
        fixture.preferences.bellSound = .named("Ping")
        fixture.preferences.sidebarWidth = 350
        fixture.preferences.sidebarColors = SidebarColors(
            background: ColorHex.color(from: "#102030"),
            foreground: ColorHex.color(from: "#a0b0c0"),
            activeWorkspaceBackground: ColorHex.color(from: "#112233"),
            activeWorkspaceForeground: ColorHex.color(from: "#223344"),
            activeTerminalRowBackground: ColorHex.color(from: "#334455"),
            activeTerminalRowForeground: ColorHex.color(from: "#445566"),
            pillBackground: ColorHex.color(from: "#556677"),
            pillForeground: ColorHex.color(from: "#667788"))
        let group = WorkspaceGroup(name: "Research")
        fixture.store.groups = [group]
        fixture.preferences.selectedGroupId = group.id

        for source in [fixture.store as any SettingsPairSource, fixture.preferences] {
            let emittedScalars = Set(source.settingsPairs.map(\.key))
                .intersection(SettingsKeys.scalars)
            #expect(emittedScalars.subtracting(source.ownedKeys).isEmpty)
        }
    }

    /// And together they emit every scalar, so no managed key is left to the
    /// preservation path on a normal write.
    @Test func theTwoSourcesTogetherEmitEveryManagedScalar() {
        let fixture = SettingsFixture(config: WiettyConfigFile.temporary())
        fixture.preferences.sidebarColors = SidebarColors(
            background: ColorHex.color(from: "#102030"),
            foreground: ColorHex.color(from: "#a0b0c0"),
            activeWorkspaceBackground: ColorHex.color(from: "#112233"),
            activeWorkspaceForeground: ColorHex.color(from: "#223344"),
            activeTerminalRowBackground: ColorHex.color(from: "#334455"),
            activeTerminalRowForeground: ColorHex.color(from: "#445566"),
            pillBackground: ColorHex.color(from: "#556677"),
            pillForeground: ColorHex.color(from: "#667788"))
        let group = WorkspaceGroup(name: "Research")
        fixture.store.groups = [group]
        fixture.preferences.selectedGroupId = group.id

        let emitted = Set(fixture.store.settingsPairs.map(\.key))
            .union(fixture.preferences.settingsPairs.map(\.key))
        #expect(SettingsKeys.scalars.subtracting(emitted).isEmpty)
    }
}
