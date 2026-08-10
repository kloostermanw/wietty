import SwiftUI

/// Presents update-related alerts driven by `UpdateService.state`.
struct UpdateAlertModifier: ViewModifier {
    @Bindable var updates: UpdateService

    func body(content: Content) -> some View {
        content
            .alert(
                "Update available",
                isPresented: presentedBinding { if case .available = $0 { true } else { false } },
                presenting: availableRelease
            ) { release in
                Button("Download") { Task { await updates.download(release) } }
                Button("Skip This Version") { updates.skip(release) }
                Button("Later", role: .cancel) { updates.dismiss() }
            } message: { release in
                let notes = release.body.isEmpty ? "" : "\n\n\(release.body)"
                Text("Wietty \(release.version.description) is available. You have \(AppVersion.current.description).\(notes)")
            }
            .alert(
                "You are up to date",
                isPresented: presentedBinding { $0 == .upToDate }
            ) {
                Button("OK", role: .cancel) { updates.dismiss() }
            } message: {
                Text("Wietty \(AppVersion.current.description) is the latest version.")
            }
            .alert(
                "Update check failed",
                isPresented: presentedBinding { if case .failed = $0 { true } else { false } },
                presenting: failedMessage
            ) { _ in
                Button("OK", role: .cancel) { updates.dismiss() }
            } message: { message in
                Text(message)
            }
            .alert(
                "Download complete",
                isPresented: presentedBinding { if case .downloaded = $0 { true } else { false } }
            ) {
                Button("OK", role: .cancel) { updates.dismiss() }
            } message: {
                Text("The installer was revealed in Finder. Open it, then drag Wietty to your Applications folder.")
            }
    }

    private func presentedBinding(_ isActive: @escaping (UpdateService.State) -> Bool) -> Binding<Bool> {
        Binding(
            get: { isActive(updates.state) },
            set: { if !$0 { updates.dismiss() } }
        )
    }

    private var availableRelease: GitHubRelease? {
        if case let .available(release) = updates.state { return release }
        return nil
    }

    private var failedMessage: String? {
        if case let .failed(message) = updates.state { return message }
        return nil
    }
}

extension View {
    func updateAlerts(_ updates: UpdateService) -> some View {
        modifier(UpdateAlertModifier(updates: updates))
    }
}
