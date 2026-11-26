import Foundation
import WiettyCore

/// The servers the app runs, and the teardown that closes its terminals at quit.
///
/// Owned by `WiettyApp` rather than by `ContentView`, which is where all of this
/// used to live. The two coincide today because there is one `Window` scene, so this
/// changes no behaviour on its own. It is here for what comes next: phase 5 has the
/// app find a server process that is already running, start one if there is none,
/// attach, and offer an explicit stop (issue #84). A view cannot be the thing that
/// adopts a process it did not start, and a server whose lifetime is a view's
/// quietly becomes one again the moment a second scene exists.
///
/// In the app target, not the core. What it holds is core, but deciding to run it is
/// composition, and the quit teardown it owns needs AppKit.
@MainActor
@Observable
final class ServerRuntime {
    private var mcpHost: MCPServerHost?
    private var remoteServer: RemoteServer?
    /// Closes every terminal when the app quits. Held here so it lives as long as
    /// the servers do, which is as long as the app does.
    private var quitTeardown: TerminalQuitTeardown?

    /// Brings up everything that should be running at launch.
    ///
    /// Idempotent on the MCP host: one host for the app's life, because a port change
    /// or a Restart restarts this one rather than building another, so only one
    /// server ever reports into `store.mcpStatus`.
    func start(store: ProjectStore, terminals: TerminalStack) async {
        if quitTeardown == nil, terminals.ghostty.ghosttyService != nil {
            quitTeardown = TerminalQuitTeardown(stack: terminals.ghostty,
                                                remotePanes: terminals.remotePanes)
        }
        if mcpHost == nil {
            let host = MCPServerHost(router: MCPToolRouter(store: store, port: store.mcpPort),
                                     port: store.mcpPort,
                                     onStatusChange: { status in store.mcpStatus = status })
            mcpHost = host
            await host.start()
        }
        await syncRemote(store: store, terminals: terminals)
    }

    /// Starts or stops `RemoteServer` to match `store.remoteEnabled`. When the port
    /// changes, `forceRestart` tears down the running server first so it rebinds on
    /// the new port.
    func syncRemote(store: ProjectStore, terminals: TerminalStack,
                    forceRestart: Bool = false) async {
        if store.remoteEnabled {
            if forceRestart, remoteServer != nil {
                remoteServer?.stop()
                remoteServer = nil
            }
            if remoteServer == nil {
                store.remoteStartupError = nil
                let server = RemoteServer(store: store, streamer: terminals.streamer,
                                          token: store.remoteToken, port: store.remotePort,
                                          onStartupError: { message in store.remoteStartupError = message })
                remoteServer = server
                await server.start()
            }
        } else {
            remoteServer?.stop()
            remoteServer = nil
            // The hub is deliberately left running. It is shared with the panes' own
            // viewers, which reach it through `GhosttyStack.localServer` whether or
            // not this server runs, and its `stop()` cancels the flush timer for
            // good, so stopping it here would leave every later local viewer silent. Tearing the server
            // down closes its sockets anyway, and each socket detaches its own viewer
            // on the way out.
            store.remoteStartupError = nil
        }
    }

    /// Restarts the MCP server on the port it already has. The status bar's and the
    /// Settings tab's Restart.
    func restartMCP() {
        Task { await mcpHost?.restart() }
    }

    /// Restarts the MCP server on a port that has just changed in Settings.
    func setMCPPort(_ port: Int) async {
        await mcpHost?.restart(port: port)
    }
}
