import Testing
import Foundation
@testable import Wietty

/// Giving a workspace its own name.
///
/// The name a workspace shows is its folder's unless something overrides it, and
/// there are two overrides with a precedence between them: the `name` in the
/// workspace's committed `wietty.json`, and this one, which the user types in
/// this app and which is stored locally.
@MainActor
@Suite struct WorkspaceRenameTests {
    private func tempFolder(named name: String) -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rename-\(UUID().uuidString)")
            .appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test.\(UUID().uuidString)")!
    }

    private func store(_ defaults: UserDefaults) -> ProjectStore {
        ProjectStore(defaults: defaults, service: FakeTerminalService())
    }

    private func addProject(_ store: ProjectStore, named name: String) -> Project {
        store.addProject(url: tempFolder(named: name))
        return store.projects.last!
    }

    /// A workspace whose committed `wietty.json` names it, through the real path
    /// rather than a test-only setter: the file is written and the store reads it.
    private func addProject(_ store: ProjectStore, named name: String,
                            configName: String) throws -> Project {
        let folder = tempFolder(named: name)
        try ConfigFile.write(WorkspaceConfig(name: configName, agents: [], terminals: []), in: folder)
        store.addProject(url: folder)
        return store.projects.last!
    }

    @Test func aWorkspaceIsItsFolderNameUntilItIsRenamed() {
        let store = store(makeDefaults())
        let project = addProject(store, named: "api-service")
        #expect(project.name == "api-service")
    }

    @Test func renamingChangesTheNameItShows() {
        let store = store(makeDefaults())
        let project = addProject(store, named: "api-service")

        store.renameWorkspace(project, to: "Payments API")

        #expect(store.projects.first?.name == "Payments API")
    }

    /// The whole point of storing it: the name is still there on the next launch.
    @Test func aRenameSurvivesARelaunch() {
        let defaults = makeDefaults()
        let first = store(defaults)
        let project = addProject(first, named: "api-service")

        first.renameWorkspace(project, to: "Payments API")

        #expect(store(defaults).projects.first?.name == "Payments API")
    }

    /// The typed name wins over the one in the workspace's config file. It has to:
    /// a rename that silently did nothing for exactly those workspaces that carry a
    /// `name` in `wietty.json` would look broken, and the user asking here is
    /// more specific than a file that travelled in with the repository.
    @Test func aTypedNameWinsOverTheConfigFile() throws {
        let store = store(makeDefaults())
        let project = try addProject(store, named: "api-service", configName: "From config")
        #expect(store.projects.first?.name == "From config")

        store.renameWorkspace(project, to: "Payments API")

        #expect(store.projects.first?.name == "Payments API")
    }

    /// Clearing the field puts the workspace back to what it would be called
    /// without a rename, which is the only way to undo one: the config file's name
    /// if it has one, otherwise the folder.
    @Test func anEmptyNameRestoresTheNameUnderneath() throws {
        let store = store(makeDefaults())
        let project = try addProject(store, named: "api-service", configName: "From config")
        store.renameWorkspace(project, to: "Payments API")

        store.renameWorkspace(project, to: "   ")

        #expect(store.projects.first?.name == "From config")
    }

    /// Surrounding whitespace is not part of a name. Storing it would leave a
    /// workspace that looks misaligned in the sidebar for a reason nobody can see.
    @Test func aTypedNameIsTrimmed() {
        let store = store(makeDefaults())
        let project = addProject(store, named: "api-service")

        store.renameWorkspace(project, to: "  Payments API  ")

        #expect(store.projects.first?.name == "Payments API")
    }

    /// Renaming one workspace leaves every other alone, which the sidebar depends
    /// on: the rename is keyed by id, not by position or by name.
    @Test func renamingOneWorkspaceLeavesTheOthers() {
        let store = store(makeDefaults())
        let first = addProject(store, named: "api-service")
        _ = addProject(store, named: "web-app")

        store.renameWorkspace(first, to: "Payments API")

        #expect(store.projects.map(\.name) == ["Payments API", "web-app"])
    }
}
